begin;
create function requests_app.enqueue(k text, c bigint, body text, buttons jsonb default null, t uuid default null, kind text default 'message', sender bigint default null)
returns void language plpgsql security definer set search_path=pg_catalog,requests_app as $$
begin
 insert into requests_app.outbox(effect_key,ticket_id,payload,kind,sender_chat_id)
 values(k,t,jsonb_strip_nulls(jsonb_build_object('chat_id',c,'text',body,'reply_markup',buttons)),kind,sender)
 on conflict(effect_key) do nothing;
end $$;
create function requests_app.status_label(s text) returns text language sql immutable set search_path=pg_catalog as $$
 select case s when 'new' then 'Новая' when 'in_progress' then 'В работе' when 'done' then 'Завершена' else 'Черновик' end
$$;
create function requests_app.btn(label text, data text) returns jsonb language sql immutable set search_path=pg_catalog as $$
 select jsonb_build_object('text',label,'callback_data',data)
$$;
create function requests_app.card(k text,c bigint,t requests_app.tickets,owner boolean) returns void language plpgsql security definer set search_path=pg_catalog,requests_app as $$
declare b jsonb;
begin
 b:=jsonb_build_array(jsonb_build_array(requests_app.btn(case when owner then 'Ответить' else 'Написать уточнение' end,'p:'||t.number),requests_app.btn('История','h:'||t.number||':0')));
 if owner then b:=b||jsonb_build_array(jsonb_build_array(requests_app.btn('В работу','s:'||t.number||':in_progress'),requests_app.btn('Завершить','s:'||t.number||':done'))); end if;
 b:=b||jsonb_build_array(jsonb_build_array(requests_app.btn('← К списку','l:all:0')));
 perform requests_app.enqueue(k,c,'Обращение №'||t.number||E'\nИмя: '||t.name||E'\nТема: '||t.subject||E'\nСтатус: '||requests_app.status_label(t.status)||E'\n\n'||t.description,jsonb_build_object('inline_keyboard',b),t.id);
end $$;
create function public.nr_create_draft(p_id uuid,p_name text,p_subject text,p_description text,p_code_hash text,p_ip_hash text) returns jsonb language plpgsql security definer set search_path=pg_catalog,requests_app as $$
declare t requests_app.tickets;
begin
 if p_id is null or p_name is null or p_subject is null or p_description is null or p_code_hash is null or p_ip_hash is null then raise exception 'invalid_form';end if;
 if char_length(p_name) not between 1 and 80 or char_length(p_subject) not between 1 and 120 or char_length(p_description) not between 5 and 2000 or p_code_hash !~ '^[a-f0-9]{64}$' or p_ip_hash !~ '^[a-f0-9]{64}$' then raise exception 'invalid_form';end if;
 -- This short global transaction lock serializes rate admission and idempotency.
 perform pg_advisory_xact_lock(17701001);
 select * into t from requests_app.tickets where id=p_id;
 if found then
  if t.name<>p_name or t.subject<>p_subject or t.description<>p_description or t.code_hash<>p_code_hash then raise exception 'idempotency_conflict'; end if;
  if t.expires_at<=now() then raise exception 'draft_expired';end if;
  return jsonb_build_object('expires_at',t.expires_at);
 end if;
 if (select count(*) from requests_app.tickets where ip_hash=p_ip_hash and created_at>now()-interval '10 minutes')>=10 or (select count(*) from requests_app.tickets where created_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')>=500 then raise exception 'form_rate_limit'; end if;
 delete from requests_app.tickets where status='draft' and created_at<now()-interval '1 day';
 insert into requests_app.tickets(id,name,subject,description,code_hash,ip_hash) values(p_id,p_name,p_subject,p_description,p_code_hash,p_ip_hash) returning * into t;
 return jsonb_build_object('expires_at',t.expires_at);
end $$;

create function public.nr_handle_update(p_update jsonb,p_admin bigint,p_code_hash text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,requests_app as $$
declare m jsonb; f jsonb; cb jsonb; uid bigint; actor bigint; c bigint; txt text; data text; k text; t requests_app.tickets; pr requests_app.prompts; row_item record; owner boolean; n bigint; page int:=0; filter text:='all'; parts text[]; buttons jsonb:='[]'::jsonb; total bigint; o requests_app.outbox; count_rate bigint; mid bigint;
begin
 if jsonb_typeof(p_update) is distinct from 'object' or jsonb_typeof(p_update->'update_id') is distinct from 'number' then raise exception 'invalid_update';end if;
 uid:=(p_update->>'update_id')::bigint;
 cb:=p_update->'callback_query';m:=coalesce(cb->'message',p_update->'message');f:=coalesce(cb->'from',m->'from');
 if m is null or f is null or m->'chat'->>'type' is distinct from 'private' or coalesce((f->>'is_bot')::boolean,true) or jsonb_typeof(f->'id') is distinct from 'number' or jsonb_typeof(m->'chat'->'id') is distinct from 'number' then return jsonb_build_object('ignored',true);end if;
 actor:=(f->>'id')::bigint;c:=(m->'chat'->>'id')::bigint;
 if actor<>c or actor<=0 then return jsonb_build_object('ignored',true);end if;
 owner:=coalesce(p_admin,0)>0 and actor=p_admin;
 perform pg_advisory_xact_lock(actor);
 insert into requests_app.updates(update_id,actor_id) values(uid,actor) on conflict do nothing;
 if not found then return jsonb_build_object('duplicate',true);end if;
 k:='u:'||uid;
 select count(*) into count_rate from requests_app.updates where actor_id=actor and created_at>now()-interval '1 minute';
 if count_rate>30 then
  if count_rate=31 then perform requests_app.enqueue(k,c,'Слишком много действий. Подождите минуту.');end if;
  return jsonb_build_object('rate_limited',true);
 end if;
 txt:=coalesce(m->>'text','');data:=coalesce(cb->>'data','');
 if cb is not null and octet_length(data)>64 then return jsonb_build_object('ignored',true);end if;
 if cb is null and char_length(txt)>2000 then perform requests_app.enqueue(k,c,'Текст должен быть не длиннее 2000 символов.');return '{}'::jsonb;end if;
 if cb is null and txt ~ '^/id(@[A-Za-z0-9_]+)?$' then
  perform requests_app.enqueue(k,c,'Ваш Telegram ID: '||actor);return '{}'::jsonb;
 end if;
 if cb is null and txt ~ '^/start ' then
  if p_code_hash is null then perform requests_app.enqueue(k,c,'Ссылка недействительна или истекла. Вернитесь к форме и создайте новый черновик.');return '{}'::jsonb;end if;
  select * into t from requests_app.tickets where code_hash=p_code_hash for update;
  if not found then perform requests_app.enqueue(k,c,'Ссылка недействительна или истекла. Вернитесь к форме.');
  elsif t.chat_id=c then perform requests_app.card(k,c,t,owner);
  elsif t.chat_id is not null or t.expires_at<=now() then perform requests_app.enqueue(k,c,'Ссылка недействительна или уже использована. Создайте своё обращение через форму.');
  elsif coalesce(p_admin,0)<=0 then perform requests_app.enqueue(k,c,'Приём обращений пока не настроен. Попробуйте позже.');
  else
   update requests_app.tickets set chat_id=c,status='new',confirmed_at=now(),updated_at=now() where id=t.id returning * into t;
   perform requests_app.enqueue(k||':accepted',c,'Обращение №'||t.number||' принято. Ответ придёт сюда. Список ваших обращений: /my',null,t.id);
   perform requests_app.card(k||':owner',p_admin,t,true);
  end if;
  return '{}'::jsonb;
 end if;
 -- Replies always use the persisted (chat_id, prompt message_id) pair.
 if cb is null and m ? 'reply_to_message' then
  mid:=(m->'reply_to_message'->>'message_id')::bigint;
  select * into pr from requests_app.prompts where chat_id=c and message_id=mid;
  if not found then
   if exists(select 1 from requests_app.outbox where kind='prompt' and payload->>'chat_id'=c::text and state in ('pending','processing')) then
    -- Raising rolls back update_id as well. Telegram must retry this update.
    raise exception 'retry_prompt' using errcode='P0001';
   end if;
   perform requests_app.enqueue(k,c,'Подсказка не найдена. Откройте /my или /requests и выберите обращение.');return '{}'::jsonb;
  end if;
  select * into t from requests_app.tickets where id=pr.ticket_id for update;
  if t.status='draft' or (not owner and t.chat_id<>c) then perform requests_app.enqueue(k,c,'Нет доступа к этому обращению.');return '{}'::jsonb;end if;
  if char_length(btrim(txt))<1 then perform requests_app.enqueue(k,c,'Поддерживается только текст до 2000 символов. Ответьте текстом на подсказку.');return '{}'::jsonb;end if;
  if coalesce(p_admin,0)<=0 then raise exception 'not_configured';end if;
  insert into requests_app.messages(ticket_id,sender_chat_id,sender_role,body) values(t.id,c,case when owner then 'owner' else 'client' end,txt);
  perform requests_app.enqueue(k||':saved',c,'Сообщение к обращению №'||t.number||' сохранено. Подтверждение доставки придёт отдельно.',null,t.id);
  perform requests_app.enqueue(k||':forward',case when owner then t.chat_id else p_admin end,'Обращение №'||t.number||case when owner then E' · Ответ\n\n' else E' · Уточнение\n\n' end||txt,jsonb_build_object('inline_keyboard',jsonb_build_array(jsonb_build_array(requests_app.btn('Открыть обращение','c:'||t.number)))),t.id,'forward',c);
  return '{}'::jsonb;
 end if;
 if cb is null then
  if txt ~ '^/requests(@[A-Za-z0-9_]+)?$' then if not owner then perform requests_app.enqueue(k,c,'Эта команда доступна только владельцу. Ваши обращения: /my');return '{}'::jsonb;end if;data:='l:new:0';
  elsif txt ~ '^/my(@[A-Za-z0-9_]+)?$' then data:='l:all:0';
  elsif txt ~ '^/retry(@[A-Za-z0-9_]+)?$' then data:='errors:0';
  else perform requests_app.enqueue(k,c,'Чтобы выбрать обращение, используйте /my'||case when owner then ' или /requests' else '' end||'. Для отправки текста нажмите «Ответить» или «Написать уточнение» и ответьте на подсказку. Вложения не поддерживаются. Ваш ID: /id');return '{}'::jsonb;
  end if;
 end if;
 parts:=string_to_array(data,':');
 if parts[1]='l' then
  filter:=coalesce(parts[2],'all');if filter not in ('new','in_progress','all') then return '{}'::jsonb;end if;
  if coalesce(parts[3],'') !~ '^\d{1,6}$' then return '{}'::jsonb;end if;page:=parts[3]::int;
  if not owner and filter<>'all' then perform requests_app.enqueue(k,c,'Нет доступа. Ваши обращения: /my');return '{}'::jsonb;end if;
  select count(*) into total from requests_app.tickets where status<>'draft' and (owner or chat_id=c) and (filter='all' or status=filter);
  for row_item in select * from requests_app.tickets where status<>'draft' and (owner or chat_id=c) and (filter='all' or status=filter) order by number desc limit 8 offset page*8 loop
   buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('№'||row_item.number||' · '||left(row_item.subject,35)||' · '||requests_app.status_label(row_item.status),'c:'||row_item.number)));
  end loop;
  if page>0 then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('← Назад','l:'||filter||':'||(page-1))));end if;
  if (page+1)*8<total then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('Далее →','l:'||filter||':'||(page+1))));end if;
  if owner then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('Новые','l:new:0'),requests_app.btn('В работе','l:in_progress:0'),requests_app.btn('Все','l:all:0')));end if;
  perform requests_app.enqueue(k,c,case when owner then 'Обращения' else 'Ваши обращения' end||' · '||total||' · страница '||(page+1),jsonb_build_object('inline_keyboard',buttons));
 elsif parts[1] in ('errors','r') then
  if not owner then perform requests_app.enqueue(k,c,'Нет доступа.');return '{}'::jsonb;end if;
  if parts[1]='r' and coalesce(parts[2],'') ~ '^\d{1,18}$' then
   select * into o from requests_app.outbox where id=parts[2]::bigint for update;
   if found and o.state='failed' then update requests_app.outbox set state='pending',error_code=null where id=o.id;perform requests_app.enqueue(k,c,'Повтор доставки поставлен в очередь. При неопределённом результате предыдущей отправки возможен дубль.');else perform requests_app.enqueue(k,c,'Повтор не требуется или уже выполняется.');end if;
  elsif parts[1]='errors' and coalesce(parts[2],'') ~ '^\d{1,6}$' then
   page:=parts[2]::int;
   select count(*) into total from requests_app.outbox where state='failed';
   for row_item in select * from requests_app.outbox where state='failed' order by id desc limit 8 offset page*8 loop
    buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('Повторить #'||row_item.id||' · '||coalesce(row_item.error_code,'unknown'),'r:'||row_item.id)));
   end loop;
   if page>0 then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('← Назад','errors:'||(page-1))));end if;
   if (page+1)*8<total then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('Далее →','errors:'||(page+1))));end if;
   perform requests_app.enqueue(k,c,'Ошибки доставки: '||total||'. Повтор запускайте после устранения причины, например разблокировки бота.',jsonb_build_object('inline_keyboard',buttons));
  end if;
 elsif parts[1] in ('c','p','h','s') and coalesce(parts[2],'') ~ '^\d{1,18}$' then
  n:=parts[2]::bigint;select * into t from requests_app.tickets where number=n and status<>'draft' for update;
  if not found or (not owner and t.chat_id<>c) then perform requests_app.enqueue(k,c,'Обращение не найдено или недоступно.');return '{}'::jsonb;end if;
  if parts[1]='c' then perform requests_app.card(k,c,t,owner);
  elsif parts[1]='p' then
   perform requests_app.enqueue(k,c,'Ответьте на это сообщение текстом до 2000 символов. Обращение №'||t.number||' · '||t.subject,jsonb_build_object('force_reply',true,'selective',true,'input_field_placeholder','Текст к обращению №'||t.number),t.id,'prompt');
  elsif parts[1]='s' then
   if not owner then perform requests_app.enqueue(k,c,'Статус меняет только владелец.');return '{}'::jsonb;end if;
   if parts[3] not in ('in_progress','done') or parts[3] is null then return '{}'::jsonb;end if;
   if t.status<>parts[3] then
    update requests_app.tickets set status=parts[3],updated_at=now() where id=t.id returning * into t;
    perform requests_app.enqueue(k||':status',t.chat_id,'Обращение №'||t.number||' · статус: '||requests_app.status_label(t.status),null,t.id);
   end if;
   perform requests_app.card(k,c,t,true);
  elsif parts[1]='h' and coalesce(parts[3],'') ~ '^\d{1,6}$' then
   page:=parts[3]::int;select count(*) into total from requests_app.messages where ticket_id=t.id;
   perform requests_app.enqueue(k||':heading',c,'История обращения №'||t.number||' · страница '||(page+1)||E'\nСтатус: '||requests_app.status_label(t.status)||E'\nИсходный вопрос: '||t.description,null,t.id);
   for row_item in select * from requests_app.messages where ticket_id=t.id order by id limit 5 offset page*5 loop
    perform requests_app.enqueue(k||':m:'||row_item.id,c,case when row_item.sender_role='owner' then 'Ответ' else 'Уточнение' end||' · '||to_char(row_item.created_at at time zone 'UTC','YYYY-MM-DD HH24:MI')||E' UTC\n'||row_item.body,null,t.id);
   end loop;
   buttons:=jsonb_build_array(jsonb_build_array(requests_app.btn('К карточке','c:'||t.number)));
   if page>0 then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('← Назад','h:'||t.number||':'||(page-1))));end if;
   if (page+1)*5<total then buttons:=buttons||jsonb_build_array(jsonb_build_array(requests_app.btn('Далее →','h:'||t.number||':'||(page+1))));end if;
   perform requests_app.enqueue(k||':nav',c,'Сообщений в переписке: '||total,jsonb_build_object('inline_keyboard',buttons),t.id);
  end if;
 else perform requests_app.enqueue(k,c,'Неизвестное действие. Откройте /my.');
 end if;
 return '{}'::jsonb;
end $$;

create function public.nr_claim_outbox(p_lease uuid,p_limit int default 8) returns setof requests_app.outbox language plpgsql security definer set search_path=pg_catalog,requests_app as $$
begin
 if p_lease is null then raise exception 'invalid_lease';end if;
 return query with candidates as (
  select o.id from requests_app.outbox o where (o.state='pending' or (o.state='processing' and o.leased_until<now()))
  and not exists(select 1 from requests_app.outbox earlier where earlier.id<o.id and earlier.payload->>'chat_id'=o.payload->>'chat_id' and earlier.state in ('pending','processing'))
  order by o.id limit least(greatest(p_limit,1),16) for update skip locked
 ) update requests_app.outbox o set state='processing',lease_token=p_lease,leased_until=now()+interval '60 seconds',attempts=attempts+1 from candidates where o.id=candidates.id returning o.*;
end $$;
create function public.nr_delivered(p_id bigint,p_lease uuid,p_message_id bigint) returns boolean language plpgsql security definer set search_path=pg_catalog,requests_app as $$
declare o requests_app.outbox;
begin
 select * into o from requests_app.outbox where id=p_id and state='processing' and lease_token=p_lease and leased_until>now() for update;
 if not found then return false;end if;
 if p_message_id is null or p_message_id<=0 then raise exception 'invalid_delivery';end if;
 if o.kind='prompt' then insert into requests_app.prompts(chat_id,message_id,ticket_id,outbox_id) values((o.payload->>'chat_id')::bigint,p_message_id,o.ticket_id,o.id) on conflict do nothing;end if;
 update requests_app.outbox set state='sent',lease_token=null,leased_until=null,error_code=null,telegram_message_id=p_message_id,delivered_at=now() where id=o.id;
 if o.kind='forward' and o.sender_chat_id is not null then perform requests_app.enqueue('delivered:'||o.id,o.sender_chat_id,'Сообщение к обращению №'||(select number from requests_app.tickets where id=o.ticket_id)||' доставлено в Telegram.',null,o.ticket_id);end if;
 return true;
end $$;
create function public.nr_failed(p_id bigint,p_lease uuid,p_error text) returns boolean language plpgsql security definer set search_path=pg_catalog,requests_app as $$
declare o requests_app.outbox;
begin
 select * into o from requests_app.outbox where id=p_id and state='processing' and lease_token=p_lease and leased_until>now() for update;
 if not found then return false;end if;
 update requests_app.outbox set state='failed',lease_token=null,leased_until=null,error_code=left(regexp_replace(coalesce(p_error,'transport'),'[^A-Za-z0-9_:.-]','','g'),80) where id=o.id;
 if o.kind='forward' and o.sender_chat_id is not null then perform requests_app.enqueue('failed:'||o.id,o.sender_chat_id,'Сообщение сохранено, но не доставлено. Владелец может проверить /retry. История обращения сохранена.',null,o.ticket_id);end if;
 return true;
end $$;
create function public.nr_pending_count() returns bigint language sql security definer set search_path=pg_catalog,requests_app as $$ select count(*) from requests_app.outbox where state in ('pending','processing') $$;
revoke all on all functions in schema requests_app from public,anon,authenticated;
revoke all on function public.nr_create_draft(uuid,text,text,text,text,text),public.nr_handle_update(jsonb,bigint,text),public.nr_claim_outbox(uuid,int),public.nr_delivered(bigint,uuid,bigint),public.nr_failed(bigint,uuid,text),public.nr_pending_count() from public,anon,authenticated;
grant execute on function public.nr_create_draft(uuid,text,text,text,text,text),public.nr_handle_update(jsonb,bigint,text),public.nr_claim_outbox(uuid,int),public.nr_delivered(bigint,uuid,bigint),public.nr_failed(bigint,uuid,text),public.nr_pending_count() to service_role;
commit;
