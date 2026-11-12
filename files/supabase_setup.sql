-- RUN ONCE in Supabase > SQL Editor. Change '1234' to your own admin PIN first.

create table cfg   (key text primary key, value jsonb not null default '{}');
create table rsvp  (name text primary key, status text not null check (status in ('att','may','no')),
                    adults int not null default 0, kids int not null default 0, updated_at timestamptz default now());
create table slots (name text primary key, t bigint not null, st text not null default 'p');
create table secret(pin text not null);
insert into cfg(key) values ('main');
insert into secret values ('1234');   -- <<< CHANGE THIS PIN

alter table cfg enable row level security;
alter table rsvp enable row level security;
alter table slots enable row level security;
alter table secret enable row level security;
create policy "cfg read" on cfg for select using (true);
create policy "rsvp read" on rsvp for select using (true);
create policy "rsvp insert" on rsvp for insert with check (true);
create policy "rsvp update" on rsvp for update using (true) with check (true);
create policy "slots read" on slots for select using (true);

create function check_pin(p text) returns boolean language sql security definer set search_path=public as
$$ select exists(select 1 from secret where pin=p) $$;

create function admin_save(p text, v jsonb) returns void language plpgsql security definer set search_path=public as
$$ begin
  if not check_pin(p) then raise exception 'bad pin'; end if;
  insert into cfg(key,value) values('main',v) on conflict(key) do update set value=excluded.value;
end $$;

create function add_guest(n text) returns void language sql security definer set search_path=public as
$$ update cfg set value=jsonb_set(value,'{guests}',coalesce(value->'guests','[]'::jsonb)||to_jsonb(n))
   where key='main' and not (coalesce(value->'guests','[]'::jsonb) ? n) $$;

create function book_slot(n text, m int, s bigint) returns slots language plpgsql security definer set search_path=public as
$$ declare r slots; last_t bigint; now_ms bigint := (extract(epoch from now())*1000)::bigint;
begin
  perform pg_advisory_xact_lock(42);
  select * into r from slots where name=n; if found then return r; end if;
  select coalesce(max(t),0) into last_t from slots;
  insert into slots(name,t,st) values (n, greatest(case when last_t>0 then last_t+m::bigint*60000 else 0 end, s, now_ms+60000), 'p') returning * into r;
  return r;
end $$;

create function skip_slot(n text, m int) returns slots language plpgsql security definer set search_path=public as
$$ declare r slots;
begin
  perform pg_advisory_xact_lock(42);
  update slots set t=(select coalesce(max(t),0) from slots)+m::bigint*60000 where name=n and st='p' returning * into r;
  return r;
end $$;

create function admin_slot(p text, n text, s text) returns void language plpgsql security definer set search_path=public as
$$ begin
  if not check_pin(p) then raise exception 'bad pin'; end if;
  update slots set st=s where name=n;
end $$;

insert into storage.buckets(id,name,public) values('photos','photos',true) on conflict do nothing;
create policy "photos read" on storage.objects for select using (bucket_id='photos');
create policy "photos upload" on storage.objects for insert with check (bucket_id='photos');
