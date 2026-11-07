// Shared Web API-only code. Also executed by the real SQL integration tests.
const encoder=new TextEncoder();
export class AppError extends Error{constructor(code,status=400){super(code);this.status=status;}}
export function serverKey(env){
 if(env.SERVER_DB_KEY)return env.SERVER_DB_KEY;
 const raw=env.SUPABASE_SECRET_KEYS;
 if(raw){if(raw.startsWith('sb_secret_'))return raw;try{const obj=JSON.parse(raw);if(obj&&typeof obj==='object'&&!Array.isArray(obj)){if(typeof obj.default==='string'&&obj.default)return obj.default;const first=Object.values(obj).find(x=>typeof x==='string'&&x);if(first)return first;}}catch{/* fall through to legacy */}}
 if(env.SUPABASE_SERVICE_ROLE_KEY)return env.SUPABASE_SERVICE_ROLE_KEY;
 throw new AppError('not_configured',503);
}
export function dbHeaders(key){return key.startsWith('sb_secret_')?{'apikey':key,'Content-Type':'application/json'}:{'apikey':key,'Authorization':`Bearer ${key}`,'Content-Type':'application/json'};}
export async function sha256(value){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(value))),b=>b.toString(16).padStart(2,'0')).join('');}
export async function hmac(secret,value){const k=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);const bytes=new Uint8Array(await crypto.subtle.sign('HMAC',k,encoder.encode(value)));return btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');}
export async function safeEqual(actual,expected){if(typeof actual!=='string'||typeof expected!=='string'||!expected)return false;const [a,b]=await Promise.all([sha256(actual),sha256(expected)]);let diff=0;for(let i=0;i<a.length;i++)diff|=a.charCodeAt(i)^b.charCodeAt(i);return diff===0;}
async function readJson(req,limit){
 if(!/^application\/json(?:\s*;|$)/i.test(req.headers.get('content-type')||''))throw new AppError('content_type',415);
 const declared=req.headers.get('content-length');if(declared!==null&&(!/^\d+$/.test(declared)||Number(declared)>limit))throw new AppError('body_too_large',413);
 if(!req.body)throw new AppError('invalid_json');const reader=req.body.getReader();let size=0;const chunks=[];
 for(;;){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>limit){await reader.cancel();throw new AppError('body_too_large',413);}chunks.push(value);}
 const bytes=new Uint8Array(size);let pos=0;for(const c of chunks){bytes.set(c,pos);pos+=c.length;}
 try{const data=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));if(!data||typeof data!=='object'||Array.isArray(data))throw 0;return data;}catch{throw new AppError('invalid_json');}
}
function project(env){let site,db;try{site=new URL(env.SITE_URL);db=new URL(env.SUPABASE_URL);}catch{throw new AppError('not_configured',503);}if(site.protocol!=='https:'||db.protocol!=='https:'||site.username||site.password||site.search||site.hash||db.username||db.password||db.pathname!=='/')throw new AppError('not_configured',503);return {origin:site.origin,db:db.origin};}
function botConfig(env){if(!/^\d+:[A-Za-z0-9_-]{20,}$/.test(env.BOT_TOKEN||'')||!/^[A-Za-z0-9_]{5,32}bot$/i.test(env.BOT_USERNAME||''))throw new AppError('not_configured',503);}
function strong(value){if(typeof value!=='string'||value.length<32)throw new AppError('not_configured',503);}
const errorText={not_configured:'Приём пока не настроен. Попробуйте позже.',invalid_form:'Проверьте имя, тему и описание.',invalid_json:'Некорректные данные формы.',content_type:'Нужен запрос JSON.',body_too_large:'Слишком большой запрос.',idempotency_conflict:'Данные этого запроса уже изменились. Вернитесь к форме.',draft_expired:'Срок черновика истёк. Измените текст и повторите отправку.',form_rate_limit:'Слишком много обращений. Попробуйте позже.',origin:'Этот адрес сайта не разрешён.',method:'Метод не поддерживается.',unauthorized:'Unauthorized',retry_prompt:'Повторите доставку события.',delivery_pending:'Доставка ещё выполняется.'};
function response(data,status=200,headers={}){return new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...headers}});}
export function createHandler(kind,deps={}){
 const env=deps.env||{},http=deps.fetch||fetch;
 const rpc=deps.rpc||async function(name,args={}){const {db}=project(env);const key=serverKey(env);const res=await http(`${db}/rest/v1/rpc/${name}`,{method:'POST',headers:dbHeaders(key),body:JSON.stringify(args),signal:AbortSignal.timeout(12000)});let data;try{data=await res.json();}catch{throw new AppError('database_unavailable',503);}if(!res.ok){const known=Object.keys(errorText).find(x=>data.message===x);throw new AppError(known||'database_unavailable',known==='form_rate_limit'?429:known==='idempotency_conflict'?409:known==='retry_prompt'?503:known==='draft_expired'?410:503);}return data;};
 const telegram=deps.telegram||async function(method,payload){let res,data;try{res=await http(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload),signal:AbortSignal.timeout(10000)});data=await res.json();}catch{throw new AppError('tg_transport',503);}if(!res.ok||!data.ok)throw new AppError(`tg_${Number(data.error_code)||res.status||500}`,503);return data.result;};
 async function drain(){
  // Finite webhook work; another Telegram retry/event continues the persisted queue.
  const deadline=Date.now()+25000;
  for(let round=0;round<40&&Date.now()<deadline;round++){
   const lease=crypto.randomUUID();const jobs=await rpc('nr_claim_outbox',{p_lease:lease,p_limit:8});if(!jobs.length)break;
   await Promise.all(jobs.map(async job=>{
    let delivered;
    try{delivered=await telegram(job.method,job.payload);}catch(error){await rpc('nr_failed',{p_id:job.id,p_lease:lease,p_error:/^tg_\w+$/.test(error.message)?error.message:'tg_transport'});return;}
    // If the DB write fails after Telegram success, keep the lease for recovery.
    const saved=await rpc('nr_delivered',{p_id:job.id,p_lease:lease,p_message_id:delivered.message_id});if(!saved)throw new AppError('delivery_pending',503);
   }));
  }
  if(Number(await rpc('nr_pending_count'))>0)throw new AppError('delivery_pending',503);
 }
 return async req=>{
  let cors={};
  try{
   if(kind==='create-application'){
    const {origin}=project(env);const incoming=req.headers.get('origin');
    if(incoming!==origin)throw new AppError('origin',403);
    cors={'Access-Control-Allow-Origin':origin,'Vary':'Origin','Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'Content-Type','Access-Control-Max-Age':'600'};
    if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
    if(req.method!=='POST')throw new AppError('method',405);
    botConfig(env);strong(env.FORM_SECRET);serverKey(env);
    if(!/^[1-9]\d{0,15}$/.test(env.ADMIN_CHAT_ID||'')||!Number.isSafeInteger(Number(env.ADMIN_CHAT_ID)))throw new AppError('not_configured',503);
    const body=await readJson(req,16384);const fields={};
    for(const [name,min,max] of [['name',1,80],['subject',1,120],['description',5,2000]]){if(typeof body[name]!=='string')throw new AppError('invalid_form');fields[name]=body[name].trim();const len=Array.from(fields[name]).length;if(len<min||len>max||fields[name].includes('\u0000'))throw new AppError('invalid_form');}
    if(typeof body.website!=='string'||body.website!==''||typeof body.idempotency_key!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(body.idempotency_key))throw new AppError('invalid_form');
    const uuid=body.idempotency_key.toLowerCase(),code=await hmac(env.FORM_SECRET,uuid);
    // Supabase gateway's forwarding header; use the closest hop, never a client-supplied JSON IP.
    const ip=(req.headers.get('x-forwarded-for')||'').split(',').at(-1).trim();
    if(!ip||ip.length>64||!/^[a-fA-F0-9:.]+$/.test(ip))throw new AppError('ip_unavailable',503);
    const ipHash=await sha256(await hmac(env.FORM_SECRET,`ip:${ip}`));
    const draft=await rpc('nr_create_draft',{p_id:uuid,p_name:fields.name,p_subject:fields.subject,p_description:fields.description,p_code_hash:await sha256(code),p_ip_hash:ipHash});
    return response({telegram_url:`https://t.me/${env.BOT_USERNAME}?start=${code}`,expires_at:draft.expires_at},200,cors);
   }
   if(kind==='telegram-hook'){
    // Authenticate before parsing, configuration checks, DB calls or transport calls.
    if(!await safeEqual(req.headers.get('X-Telegram-Bot-Api-Secret-Token'),env.TG_WEBHOOK_SECRET))throw new AppError('unauthorized',401);
    if(req.method!=='POST')throw new AppError('method',405);
    botConfig(env);project(env);serverKey(env);strong(env.TG_WEBHOOK_SECRET);
    const update=await readJson(req,65536);
    if(!Number.isSafeInteger(update.update_id)||update.update_id<0)throw new AppError('invalid_update');
    const start=typeof update.message?.text==='string'?update.message.text.match(/^\/start ([-_A-Za-z0-9]{43})$/):null;
    const admin=/^[1-9]\d{0,15}$/.test(env.ADMIN_CHAT_ID||'')?Number(env.ADMIN_CHAT_ID):0;
    await rpc('nr_handle_update',{p_update:update,p_admin:Number.isSafeInteger(admin)?admin:0,p_code_hash:start?await sha256(start[1]):null});
    if(typeof update.callback_query?.id==='string'){
     try{await telegram('answerCallbackQuery',{callback_query_id:update.callback_query.id});}catch{/* Callback may have expired; persistent effects still drain. */}
    }
    await drain();return response({ok:true});
   }
   if(kind==='setup-telegram'){
    if(!await safeEqual(req.headers.get('X-Setup-Secret'),env.SETUP_SECRET))throw new AppError('unauthorized',401);
    if(req.method!=='POST')throw new AppError('method',405);
    strong(env.SETUP_SECRET);strong(env.TG_WEBHOOK_SECRET);botConfig(env);const {db}=project(env);
    const {action}=await readJson(req,1024),hook=`${db}/functions/v1/telegram-hook`;
    if(action==='register'){
     if(!/^[A-Za-z0-9_-]{32,256}$/.test(env.TG_WEBHOOK_SECRET))throw new AppError('not_configured',503);
     const me=await telegram('getMe',{});if(!me.is_bot||me.username!==env.BOT_USERNAME)throw new AppError('bot_mismatch',409);
     await telegram('setWebhook',{url:hook,secret_token:env.TG_WEBHOOK_SECRET,allowed_updates:['message','callback_query'],drop_pending_updates:false,max_connections:8});
     return response({ok:true,webhook_url:hook});
    }
    if(action==='status'){
     const info=await telegram('getWebhookInfo',{});
     return response({url:info.url,expected_url:hook,matches:info.url===hook,pending_update_count:info.pending_update_count,last_error_date:info.last_error_date||null,last_error_message:info.last_error_message||null,allowed_updates:info.allowed_updates});
    }
    if(action==='test'){
     if(!/^[1-9]\d{0,15}$/.test(env.ADMIN_CHAT_ID||'')||!Number.isSafeInteger(Number(env.ADMIN_CHAT_ID)))throw new AppError('not_configured',503);
     const result=await telegram('sendMessage',{chat_id:Number(env.ADMIN_CHAT_ID),text:'Проверка подключения Атоми. Это служебное сообщение, не обращение клиента.'});return response({ok:true,message_id:result.message_id});
    }
    throw new AppError('unknown_action');
   }
   throw new AppError('unknown_function',404);
  }catch(error){const known=error instanceof AppError;return response({error:known?(errorText[error.message]||'Сервис временно недоступен. Попробуйте позже.'):'Сервис временно недоступен. Попробуйте позже.'},known?error.status:503,cors);}
 };
}
