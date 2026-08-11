-- ============================================================
-- O ESCOLHIDO — BACKEND SUPABASE
-- 8 jogadores / 9 personagens
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- TABELAS
-- ============================================================

create table if not exists public.arena_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_key_hash text not null,
  status text not null default 'lobby'
    check (status in ('lobby','selection','duel','finished')),
  phase_round integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.arena_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.arena_rooms(id) on delete cascade,
  name text not null,
  player_key_hash text not null,
  assigned_character text,
  joined_at timestamptz not null default now()
);

create unique index if not exists arena_players_unique_name
  on public.arena_players(room_id, lower(name));

create unique index if not exists arena_players_unique_character
  on public.arena_players(room_id, assigned_character)
  where assigned_character is not null;

create table if not exists public.arena_selection_choices (
  room_id uuid not null references public.arena_rooms(id) on delete cascade,
  phase_round integer not null,
  player_id uuid not null references public.arena_players(id) on delete cascade,
  character text not null,
  created_at timestamptz not null default now(),
  primary key (room_id, phase_round, player_id)
);

create table if not exists public.arena_conflicts (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.arena_rooms(id) on delete cascade,
  phase_round integer not null,
  character text not null,
  champion_id uuid not null references public.arena_players(id) on delete cascade,
  current_opponent_id uuid not null references public.arena_players(id) on delete cascade,
  waiting_ids uuid[] not null default '{}'::uuid[],
  champion_score integer not null default 0,
  opponent_score integer not null default 0,
  duel_round integer not null default 1,
  status text not null default 'active'
    check(status in ('active','done')),
  winner_id uuid references public.arena_players(id),
  created_at timestamptz not null default now()
);

create table if not exists public.arena_duel_moves (
  conflict_id uuid not null references public.arena_conflicts(id) on delete cascade,
  duel_round integer not null,
  player_id uuid not null references public.arena_players(id) on delete cascade,
  move text not null check(move in ('attack','defend','trick')),
  created_at timestamptz not null default now(),
  primary key(conflict_id, duel_round, player_id)
);

create table if not exists public.arena_logs (
  id bigserial primary key,
  room_id uuid not null references public.arena_rooms(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);

-- ============================================================
-- SEGURANÇA
-- ============================================================

alter table public.arena_rooms enable row level security;
alter table public.arena_players enable row level security;
alter table public.arena_selection_choices enable row level security;
alter table public.arena_conflicts enable row level security;
alter table public.arena_duel_moves enable row level security;
alter table public.arena_logs enable row level security;

revoke all on table public.arena_rooms from anon, authenticated;
revoke all on table public.arena_players from anon, authenticated;
revoke all on table public.arena_selection_choices from anon, authenticated;
revoke all on table public.arena_conflicts from anon, authenticated;
revoke all on table public.arena_duel_moves from anon, authenticated;
revoke all on table public.arena_logs from anon, authenticated;

-- ============================================================
-- LOG
-- ============================================================

create or replace function public.arena_log(
  p_room_id uuid,
  p_message text
)
returns void
language plpgsql
security definer
set search_path=public, extensions
as $$
begin
  insert into public.arena_logs(room_id,message)
  values(p_room_id,p_message);
end;
$$;

revoke all on function public.arena_log(uuid,text)
from public, anon, authenticated;

-- ============================================================
-- CRIAR SALA
-- ============================================================

create or replace function public.arena_create_room(
  p_code text,
  p_host_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public, extensions
as $$
declare
  v_id uuid;
  v_code text;
begin

  v_code := upper(
    regexp_replace(trim(p_code), '[^A-Z0-9]', '', 'g')
  );

  if length(v_code) < 4 or length(v_code) > 6 then
    raise exception 'O código deve ter entre 4 e 6 caracteres.';
  end if;

  if exists(
    select 1
    from public.arena_rooms
    where code=v_code
  ) then
    raise exception 'Esse código já está sendo usado. Gere outro.';
  end if;

  insert into public.arena_rooms(
    code,
    host_key_hash
  )
  values(
    v_code,
    crypt(p_host_key, gen_salt('bf'))
  )
  returning id into v_id;

  perform public.arena_log(
    v_id,
    'A sala foi criada.'
  );

  return jsonb_build_object(
    'room_id',v_id,
    'code',v_code
  );
end;
$$;

-- ============================================================
-- ENTRAR NA SALA
-- ============================================================

create or replace function public.arena_join_room(
  p_code text,
  p_name text,
  p_player_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public, extensions
as $$
declare
  v_room public.arena_rooms%rowtype;
  v_player uuid;
  v_name text;
begin

  v_name := trim(p_name);

  if length(v_name) < 1 or length(v_name) > 30 then
    raise exception 'Nome inválido.';
  end if;

  select *
  into v_room
  from public.arena_rooms
  where code=upper(trim(p_code))
  for update;

  if not found then
    raise exception 'Sala não encontrada.';
  end if;

  if v_room.status <> 'lobby' then
    raise exception 'A seleção desta sala já começou.';
  end if;

  if (
    select count(*)
    from public.arena_players
    where room_id=v_room.id
  ) >= 8 then
    raise exception 'A sala já possui 8 jogadores.';
  end if;

  if exists(
    select 1
    from public.arena_players
    where room_id=v_room.id
    and lower(name)=lower(v_name)
  ) then
    raise exception 'Já existe alguém usando esse nome.';
  end if;

  insert into public.arena_players(
    room_id,
    name,
    player_key_hash
  )
  values(
    v_room.id,
    v_name,
    crypt(p_player_key,gen_salt('bf'))
  )
  returning id into v_player;

  perform public.arena_log(
    v_room.id,
    v_name || ' entrou na sala.'
  );

  return jsonb_build_object(
    'room_id',v_room.id,
    'player_id',v_player,
    'code',v_room.code
  );
end;
$$;

-- ============================================================
-- INICIAR JOGO
-- ============================================================

create or replace function public.arena_start_game(
  p_room_id uuid,
  p_host_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public, extensions
as $$
declare
  v_room public.arena_rooms%rowtype;
  v_count int;
begin

  select *
  into v_room
  from public.arena_rooms
  where id=p_room_id
  for update;

  if not found
     or crypt(p_host_key,v_room.host_key_hash)
        <> v_room.host_key_hash then

    raise exception 'Acesso de anfitrião inválido.';
  end if;

  if v_room.status <> 'lobby' then
    raise exception 'A sala já começou.';
  end if;

  select count(*)
  into v_count
  from public.arena_players
  where room_id=p_room_id;

  if v_count <> 8 then
    raise exception 'São necessários exatamente 8 jogadores.';
  end if;

  update public.arena_rooms
  set
    status='selection',
    phase_round=1
  where id=p_room_id;

  perform public.arena_log(
    p_room_id,
    'A primeira escolha começou.'
  );

  return jsonb_build_object('ok',true);
end;
$$;

-- ============================================================
-- AVANÇAR APÓS DISPUTAS
-- ============================================================

create or replace function public.arena_advance_after_conflicts(
  p_room_id uuid
)
returns void
language plpgsql
security definer
set search_path=public, extensions
as $$
declare
  v_active int;
  v_assigned int;
  v_round int;
begin

  select count(*)
  into v_active
  from public.arena_conflicts
  where room_id=p_room_id
  and status='active';

  if v_active > 0 then
    return;
  end if;

  select count(*)
  into v_assigned
  from public.arena_players
  where room_id=p_room_id
  and assigned_character is not null;

  if v_assigned = 8 then

    update public.arena_rooms
    set status='finished'
    where id=p_room_id;

    perform public.arena_log(
      p_room_id,
      'A seleção terminou. Oito personagens encontraram seus jogadores.'
    );

  else

    update public.arena_rooms
    set
      status='selection',
      phase_round=phase_round+1
    where id=p_room_id
    returning phase_round into v_round;

    perform public.arena_log(
      p_room_id,
      'Uma nova rodada de escolhas começou.'
    );

  end if;
end;
$$;

revoke all on function public.arena_advance_after_conflicts(uuid)
from public, anon, authenticated;

-- ============================================================
-- RESOLVER ESCOLHAS
-- ============================================================

create or replace function public.arena_try_resolve_selection(
  p_room_id uuid
)
returns void
language plpgsql
security definer
set search_path=public, extensions
as $$
declare
  v_room public.arena_rooms%rowtype;

  v_needed int;
  v_submitted int;
  v_conflicts int := 0;
  v_assigned int;

  rec record;

  v_ids uuid[];
  v_wait uuid[];
begin

  select *
  into v_room
  from public.arena_rooms
  where id=p_room_id
  for update;

  if not found or v_room.status <> 'selection' then
    return;
  end if;

  select count(*)
  into v_needed
  from public.arena_players
  where room_id=p_room_id
  and assigned_character is null;

  select count(*)
  into v_submitted
  from public.arena_selection_choices c

  join public.arena_players p
    on p.id=c.player_id

  where c.room_id=p_room_id
    and c.phase_round=v_room.phase_round
    and p.assigned_character is null;

  if v_submitted < v_needed then
    return;
  end if;

  for rec in

    select
      c.character,
      array_agg(c.player_id order by random()) as ids,
      count(*) as qty

    from public.arena_selection_choices c

    join public.arena_players p
      on p.id=c.player_id

    where c.room_id=p_room_id
      and c.phase_round=v_room.phase_round
      and p.assigned_character is null

    group by c.character

  loop

    v_ids := rec.ids;

    if rec.qty = 1 then

      update public.arena_players
      set assigned_character=rec.character
      where id=v_ids[1];

      perform public.arena_log(
        p_room_id,
        (
          select name
          from public.arena_players
          where id=v_ids[1]
        )
        || ' ficou com '
        || rec.character
        || '.'
      );

    else

      v_wait :=
        case
          when array_length(v_ids,1)>2
          then v_ids[3:array_length(v_ids,1)]
          else '{}'::uuid[]
        end;

      insert into public.arena_conflicts(
        room_id,
        phase_round,
        character,
        champion_id,
        current_opponent_id,
        waiting_ids
      )
      values(
        p_room_id,
        v_room.phase_round,
        rec.character,
        v_ids[1],
        v_ids[2],
        v_wait
      );

      v_conflicts := v_conflicts + 1;

      perform public.arena_log(
        p_room_id,
        rec.qty::text
        || ' jogadores escolheram '
        || rec.character
        || '. Uma disputa começou.'
      );

    end if;

  end loop;

  if v_conflicts > 0 then

    update public.arena_rooms
    set status='duel'
    where id=p_room_id;

  else

    select count(*)
    into v_assigned
    from public.arena_players
    where room_id=p_room_id
    and assigned_character is not null;

    if v_assigned=8 then

      update public.arena_rooms
      set status='finished'
      where id=p_room_id;

      perform public.arena_log(
        p_room_id,
        'A seleção terminou. Oito personagens encontraram seus jogadores.'
      );

    else

      update public.arena_rooms
      set phase_round=phase_round+1
      where id=p_room_id;

    end if;

  end if;
end;
$$;

revoke all on function public.arena_try_resolve_selection(uuid)
from public, anon, authenticated;

-- ============================================================
-- ENVIAR ESCOLHA DE PERSONAGEM
-- ============================================================

create or replace function public.arena_submit_selection(
  p_room_id uuid,
  p_player_id uuid,
  p_player_key text,
  p_character text
)
returns jsonb
language plpgsql
security definer
set search_path=public, extensions
as $$
declare

  v_room public.arena_rooms%rowtype;
  v_player public.arena_players%rowtype;

  v_valid text[] :=
    array[
      'Emeline',
      'Ulisses',
      'Toni',
      'Anni',
      'Alex',
      'Rafael',
      'Julie',
      'Kendi',
      'Chiara'
    ];

begin

  select *
  into v_room
  from public.arena_rooms
  where id=p_room_id;

  if not found or v_room.status <> 'selection' then
    raise exception 'A sala não está recebendo escolhas agora.';
  end if;

  select *
  into v_player
  from public.arena_players
  where id=p_player_id
  and room_id=p_room_id;

  if not found
     or crypt(p_player_key,v_player.player_key_hash)
        <> v_player.player_key_hash then

    raise exception 'Acesso de jogador inválido.';
  end if;

  if v_player.assigned_character is not null then
    raise exception 'Você já possui um personagem.';
  end if;

  if not (p_character = any(v_valid)) then
    raise exception 'Personagem inválido.';
  end if;

  if exists(
    select 1
    from public.arena_players
    where room_id=p_room_id
    and assigned_character=p_character
  ) then
    raise exception 'Esse personagem já possui um jogador.';
  end if;

  insert into public.arena_selection_choices(
    room_id,
    phase_round,
    player_id,
    character
  )
  values(
    p_room_id,
    v_room.phase_round,
    p_player_id,
    p_character
  )

  on conflict(room_id,phase_round,player_id)

  do update set
    character=excluded.character,
    created_at=now();

  perform public.arena_try_resolve_selection(p_room_id);

  return jsonb_build_object('ok',true);
end;
$$;

-- ============================================================
-- ENVIAR MOVIMENTO DO DUELO
--
-- ATAQUE vence TRUQUE
-- TRUQUE vence DEFESA
-- DEFESA vence ATAQUE
-- ============================================================

create or replace function public.arena_submit_move(
  p_conflict_id uuid,
  p_player_id uuid,
  p_player_key text,
  p_move text
)
returns jsonb
language plpgsql
security definer
set search_path=public, extensions
as $$
declare

  c public.arena_conflicts%rowtype;
  p public.arena_players%rowtype;

  move_a text;
  move_b text;

  name_a text;
  name_b text;

  winner uuid;
  winner_name text;
  loser uuid;

  score_a int;
  score_b int;

  next_id uuid;
  next_name text;

  room_status text;

begin

  if p_move not in ('attack','defend','trick') then
    raise exception 'Movimento inválido.';
  end if;

  select *
  into c
  from public.arena_conflicts
  where id=p_conflict_id
  for update;

  if not found or c.status <> 'active' then
    raise exception 'Essa disputa já terminou.';
  end if;

  select status
  into room_status
  from public.arena_rooms
  where id=c.room_id;

  if room_status <> 'duel' then
    raise exception 'A sala não está em fase de disputa.';
  end if;

  select *
  into p
  from public.arena_players
  where id=p_player_id
  and room_id=c.room_id;

  if not found
     or crypt(p_player_key,p.player_key_hash)
        <> p.player_key_hash then

    raise exception 'Acesso de jogador inválido.';
  end if;

  if p_player_id <> c.champion_id
     and p_player_id <> c.current_opponent_id then

    raise exception 'Você não participa deste duelo agora.';
  end if;

  insert into public.arena_duel_moves(
    conflict_id,
    duel_round,
    player_id,
    move
  )
  values(
    c.id,
    c.duel_round,
    p_player_id,
    p_move
  )

  on conflict(conflict_id,duel_round,player_id)
  do nothing;

  select move
  into move_a
  from public.arena_duel_moves
  where conflict_id=c.id
    and duel_round=c.duel_round
    and player_id=c.champion_id;

  select move
  into move_b
  from public.arena_duel_moves
  where conflict_id=c.id
    and duel_round=c.duel_round
    and player_id=c.current_opponent_id;

  if move_a is null or move_b is null then

    return jsonb_build_object(
      'ok',true,
      'message','Escolha registrada.'
    );

  end if;

  select name
  into name_a
  from public.arena_players
  where id=c.champion_id;

  select name
  into name_b
  from public.arena_players
  where id=c.current_opponent_id;

  score_a := c.champion_score;
  score_b := c.opponent_score;

  -- EMPATE

  if move_a = move_b then

    perform public.arena_log(
      c.room_id,
      name_a
      || ' e '
      || name_b
      || ' escolheram a mesma ação. O round empatou.'
    );

    update public.arena_conflicts
    set duel_round=duel_round+1
    where id=c.id;

    return jsonb_build_object(
      'ok',true,
      'message','Empate. Um novo round começou.'
    );

  end if;

  -- DESCOBRE O VENCEDOR

  if
    (move_a='attack' and move_b='trick')
    or
    (move_a='trick' and move_b='defend')
    or
    (move_a='defend' and move_b='attack')
  then

    winner := c.champion_id;
    loser := c.current_opponent_id;

    score_a := score_a + 1;

    winner_name := name_a;

  else

    winner := c.current_opponent_id;
    loser := c.champion_id;

    score_b := score_b + 1;

    winner_name := name_b;

  end if;

  perform public.arena_log(
    c.room_id,

    name_a
    || ' escolheu '
    || upper(
      case move_a
        when 'attack' then 'ATAQUE'
        when 'defend' then 'DEFESA'
        else 'TRUQUE'
      end
    )

    || '; '

    || name_b
    || ' escolheu '
    || upper(
      case move_b
        when 'attack' then 'ATAQUE'
        when 'defend' then 'DEFESA'
        else 'TRUQUE'
      end
    )

    || '. '
    || winner_name
    || ' venceu o round.'
  );

  -- ALGUÉM CONSEGUIU 2 PONTOS

  if score_a >= 2 or score_b >= 2 then

    -- EXISTE OUTRO JOGADOR ESPERANDO

    if coalesce(array_length(c.waiting_ids,1),0) > 0 then

      next_id := c.waiting_ids[1];

      select name
      into next_name
      from public.arena_players
      where id=next_id;

      update public.arena_conflicts
      set
        champion_id=winner,
        current_opponent_id=next_id,

        waiting_ids=
          case
            when array_length(c.waiting_ids,1)>1
            then c.waiting_ids[2:array_length(c.waiting_ids,1)]
            else '{}'::uuid[]
          end,

        champion_score=0,
        opponent_score=0,
        duel_round=1

      where id=c.id;

      perform public.arena_log(
        c.room_id,
        winner_name
        || ' venceu o duelo por '
        || c.character
        || ' e agora enfrentará '
        || next_name
        || '.'
      );

      return jsonb_build_object(
        'ok',true,
        'message',winner_name || ' avança no torneio.'
      );

    else

      -- CAMPEÃO DEFINITIVO

      update public.arena_conflicts
      set
        champion_score=score_a,
        opponent_score=score_b,
        status='done',
        winner_id=winner
      where id=c.id;

      update public.arena_players
      set assigned_character=c.character
      where id=winner;

      perform public.arena_log(
        c.room_id,
        winner_name
        || ' conquistou '
        || c.character
        || '.'
      );

      perform public.arena_advance_after_conflicts(
        c.room_id
      );

      return jsonb_build_object(
        'ok',true,
        'message',
        winner_name
        || ' conquistou '
        || c.character
        || '!'
      );

    end if;

  else

    -- NINGUÉM CHEGOU A 2 AINDA

    update public.arena_conflicts
    set
      champion_score=score_a,
      opponent_score=score_b,
      duel_round=duel_round+1
    where id=c.id;

    return jsonb_build_object(
      'ok',true,
      'message',
      winner_name || ' venceu o round.'
    );

  end if;

end;
$$;

-- ============================================================
-- PEGAR ESTADO ATUAL DA SALA
-- ============================================================

create or replace function public.arena_get_state(
  p_room_id uuid,
  p_access_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public, extensions
as $$
declare

  r public.arena_rooms%rowtype;

  viewer_type text;
  viewer_id uuid;

  v_has_selection boolean := false;

  v_needed int := 0;
  v_submitted int := 0;

begin

  select *
  into r
  from public.arena_rooms
  where id=p_room_id;

  if not found then
    raise exception 'Sala não encontrada.';
  end if;

  -- DESCOBRIR SE É MESTRE OU JOGADOR

  if crypt(p_access_key,r.host_key_hash)
     = r.host_key_hash then

    viewer_type := 'host';

  else

    select id
    into viewer_id
    from public.arena_players

    where room_id=p_room_id
      and crypt(p_access_key,player_key_hash)
          = player_key_hash

    limit 1;

    if viewer_id is null then
      raise exception 'Acesso inválido para esta sala.';
    end if;

    viewer_type := 'player';

  end if;

  -- CONTAGEM DE ESCOLHAS

  if r.status='selection' then

    select count(*)
    into v_needed
    from public.arena_players
    where room_id=p_room_id
      and assigned_character is null;

    select count(*)
    into v_submitted
    from public.arena_selection_choices c

    join public.arena_players p
      on p.id=c.player_id

    where c.room_id=p_room_id
      and c.phase_round=r.phase_round
      and p.assigned_character is null;

    if viewer_id is not null then

      v_has_selection :=
        exists(
          select 1
          from public.arena_selection_choices

          where room_id=p_room_id
            and phase_round=r.phase_round
            and player_id=viewer_id
        );

    end if;

  end if;

  return jsonb_build_object(

    'room',

    jsonb_build_object(
      'id',r.id,
      'code',r.code,
      'status',r.status,
      'phase_round',r.phase_round,
      'selection_needed',v_needed,
      'selection_submitted',v_submitted
    ),

    'viewer',

    jsonb_build_object(
      'type',viewer_type,
      'player_id',viewer_id,
      'has_selection',v_has_selection
    ),

    'players',

    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id',p.id,
            'name',p.name,
            'assigned_character',p.assigned_character,
            'joined_at',p.joined_at
          )
          order by p.joined_at
        )

        from public.arena_players p
        where p.room_id=p_room_id
      ),

      '[]'::jsonb
    ),

    'conflicts',

    coalesce(
      (
        select jsonb_agg(

          jsonb_build_object(

            'id',c.id,
            'character',c.character,
            'status',c.status,

            'champion_id',c.champion_id,

            'current_opponent_id',
            c.current_opponent_id,

            'waiting_ids',
            to_jsonb(c.waiting_ids),

            'champion_score',
            c.champion_score,

            'opponent_score',
            c.opponent_score,

            'duel_round',
            c.duel_round,

            'viewer_submitted',

            case
              when viewer_id is null then false
              else exists(
                select 1
                from public.arena_duel_moves m
                where m.conflict_id=c.id
                  and m.duel_round=c.duel_round
                  and m.player_id=viewer_id
              )
            end

          )

          order by c.created_at
        )

        from public.arena_conflicts c

        where c.room_id=p_room_id
          and c.status='active'
      ),

      '[]'::jsonb
    ),

    'logs',

    coalesce(
      (
        select jsonb_agg(x.obj)

        from (
          select jsonb_build_object(
            'message',l.message,
            'created_at',l.created_at
          ) obj

          from public.arena_logs l

          where l.room_id=p_room_id

          order by l.id desc

          limit 60
        ) x
      ),

      '[]'::jsonb
    )

  );

end;
$$;

-- ============================================================
-- LIBERAR AS FUNÇÕES PARA O SITE
-- ============================================================

grant execute
on function public.arena_create_room(text,text)
to anon, authenticated;

grant execute
on function public.arena_join_room(text,text,text)
to anon, authenticated;

grant execute
on function public.arena_start_game(uuid,text)
to anon, authenticated;

grant execute
on function public.arena_submit_selection(uuid,uuid,text,text)
to anon, authenticated;

grant execute
on function public.arena_submit_move(uuid,uuid,text,text)
to anon, authenticated;

grant execute
on function public.arena_get_state(uuid,text)
to anon, authenticated;

-- ============================================================
-- PRONTO
-- ============================================================

-- Para apagar salas com mais de 7 dias no futuro:
--
-- delete from public.arena_rooms
-- where created_at < now() - interval '7 days';
