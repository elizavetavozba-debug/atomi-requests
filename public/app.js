'use strict';
const form=document.querySelector('#application'), button=document.querySelector('#submit'), status=document.querySelector('#status');
const config=window.REQUESTS_CONFIG||{};
const fields=['name','subject','description'];
let attempt=null, busy=false;
const length=s=>Array.from(s).length;
function notice(text,error=false){status.textContent=text;status.classList.toggle('error',error);}
function configured(){try{const u=new URL(config.createApplicationUrl);return u.protocol==='https:'&&u.pathname.endsWith('/functions/v1/create-application')&&!u.username&&!u.password&&!u.search&&!u.hash&&/^[A-Za-z0-9_]{5,32}bot$/i.test(config.botUsername);}catch{return false;}}
for(const name of fields){const input=form.elements[name];input.addEventListener('input',()=>{document.querySelector(`#${name}-count`).textContent=`${length(input.value)} / ${input.maxLength}`;input.removeAttribute('aria-invalid');});}
button.disabled=!configured();if(configured())notice('');
form.addEventListener('submit',async event=>{event.preventDefault();if(busy||!configured())return;
const data=Object.fromEntries(fields.map(name=>[name,form.elements[name].value.trim()]));
for(const [name,min,max,label] of [['name',1,80,'Имя'],['subject',1,120,'Тема'],['description',5,2000,'Описание']]){if(length(data[name])<min||length(data[name])>max){form.elements[name].setAttribute('aria-invalid','true');form.elements[name].focus();notice(`${label}: от ${min} до ${max} символов.`,true);return;}}
const fingerprint=JSON.stringify(data);if(!attempt||attempt.fingerprint!==fingerprint)attempt={fingerprint,id:crypto.randomUUID()};
busy=true;button.disabled=true;notice('Сохраняем черновик…');const abort=new AbortController(),timer=setTimeout(()=>abort.abort(),20000);
try{const response=await fetch(config.createApplicationUrl,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...data,idempotency_key:attempt.id,website:form.elements.website.value}),signal:abort.signal,credentials:'omit',referrerPolicy:'no-referrer'});let result;try{result=await response.json();}catch{throw new Error('Сервис временно недоступен. Попробуйте ещё раз.');}if(!response.ok){if(response.status===410)attempt=null;throw new Error(result.error||'Не удалось сохранить черновик. Попробуйте ещё раз.');}
const url=new URL(result.telegram_url);if(url.protocol!=='https:'||url.hostname!=='t.me'||url.port||url.username||url.password||url.hash||url.pathname!==`/${config.botUsername}`||url.searchParams.size!==1||!/^[-_A-Za-z0-9]{43}$/.test(url.searchParams.get('start')||''))throw new Error('Сервис вернул некорректную ссылку. Попробуйте позже.');
const expires=Date.parse(result.expires_at);if(!Number.isFinite(expires))throw new Error('Не удалось проверить срок ссылки. Попробуйте позже.');
document.querySelector('#telegram-link').href=url.href;document.querySelector('#expiry').textContent=`Ссылка действует до ${new Date(expires).toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'})} по времени вашего устройства (30 минут с создания).`;
document.querySelector('#form-step').hidden=true;document.querySelector('#confirm-step').hidden=false;document.querySelector('#step-label').textContent='ШАГ 2 / 2';notice('');document.querySelector('#telegram-link').focus();
}catch(error){notice(error.name==='AbortError'?'Сервис не ответил вовремя. Текст сохранён в форме; повторите попытку.':error.message,true);}finally{clearTimeout(timer);busy=false;button.disabled=!configured();}});
document.querySelector('#back').addEventListener('click',()=>{document.querySelector('#form-step').hidden=false;document.querySelector('#confirm-step').hidden=true;document.querySelector('#step-label').textContent='ШАГ 1 / 2';form.elements.name.focus();notice('');});
