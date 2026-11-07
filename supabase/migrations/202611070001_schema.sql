-- Dedicated application schema. No existing application tables are modified.
begin;
create schema if not exists requests_app;
revoke all on schema requests_app from public, anon, authenticated;
create table requests_app.tickets (
 id uuid primary key, number bigint generated always as identity unique,
 name text not null check(char_length(name) between 1 and 80),
 subject text not null check(char_length(subject) between 1 and 120),
 description text not null check(char_length(description) between 5 and 2000),
 status text not null default 'draft' check(status in ('draft','new','in_progress','done')),
 code_hash text not null unique check(code_hash ~ '^[a-f0-9]{64}$'),
 ip_hash text not null check(ip_hash ~ '^[a-f0-9]{64}$'),
 chat_id bigint, created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '30 minutes',
 confirmed_at timestamptz, updated_at timestamptz not null default now(),
 check((status='draft' and chat_id is null and confirmed_at is null) or (status<>'draft' and chat_id>0 and confirmed_at is not null))
);
create index on requests_app.tickets(chat_id,number desc);
create index on requests_app.tickets(created_at);
create index on requests_app.tickets(ip_hash,created_at);
create table requests_app.messages (
 id bigint generated always as identity primary key, ticket_id uuid not null references requests_app.tickets(id),
 sender_chat_id bigint not null, sender_role text not null check(sender_role in ('owner','client')),
 body text not null check(char_length(body) between 1 and 2000), created_at timestamptz not null default now()
);
create index on requests_app.messages(ticket_id,id);
create table requests_app.updates (update_id bigint primary key, actor_id bigint not null, created_at timestamptz not null default now());
create index on requests_app.updates(actor_id,created_at);
create table requests_app.outbox (
 id bigint generated always as identity primary key, effect_key text not null unique,
 ticket_id uuid references requests_app.tickets(id), method text not null default 'sendMessage' check(method in ('sendMessage')),
 payload jsonb not null, kind text not null default 'message' check(kind in ('message','prompt','forward')),
 sender_chat_id bigint, state text not null default 'pending' check(state in ('pending','processing','sent','failed')),
 attempts int not null default 0, lease_token uuid, leased_until timestamptz,
 error_code text, telegram_message_id bigint, created_at timestamptz not null default now(), delivered_at timestamptz,
 check((state='processing' and lease_token is not null and leased_until is not null) or (state<>'processing' and lease_token is null and leased_until is null))
);
create index on requests_app.outbox(state,leased_until,id);
create table requests_app.prompts (
 chat_id bigint not null, message_id bigint not null, ticket_id uuid not null references requests_app.tickets(id),
 outbox_id bigint not null unique references requests_app.outbox(id), created_at timestamptz not null default now(),
 primary key(chat_id,message_id)
);
-- There are intentionally no client RLS policies.
alter table requests_app.tickets enable row level security;
alter table requests_app.messages enable row level security;
alter table requests_app.updates enable row level security;
alter table requests_app.outbox enable row level security;
alter table requests_app.prompts enable row level security;
revoke all on all tables in schema requests_app from public,anon,authenticated;
revoke all on all sequences in schema requests_app from public,anon,authenticated;
alter default privileges in schema requests_app revoke all on tables from public,anon,authenticated;
alter default privileges in schema requests_app revoke all on sequences from public,anon,authenticated;
alter default privileges in schema requests_app revoke execute on functions from public,anon,authenticated;
commit;

-- Server RPC composite types remain inaccessible to browser roles.
grant usage on schema requests_app to service_role;
