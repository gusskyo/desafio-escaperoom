(() => {
  'use strict';

  const CHARACTERS = [
    'Emeline', 'Ulisses', 'Toni', 'Anni', 'Alex', 'Rafael', 'Julie', 'Kendi', 'Chiara'
  ];
  const MOVES = {
    attack: { label: 'ATAQUE', beats: 'trick', hint: 'vence Truque' },
    defend: { label: 'DEFESA', beats: 'attack', hint: 'vence Ataque' },
    trick:  { label: 'TRUQUE', beats: 'defend', hint: 'vence Defesa' }
  };

  const app = document.getElementById('app');
  const toast = document.getElementById('toast');
  const cfg = window.ARENA_CONFIG || {};
  const configured = cfg.supabaseUrl && cfg.supabaseKey && !cfg.supabaseUrl.includes('COLE_') && !cfg.supabaseKey.includes('COLE_');
  const client = configured ? window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey) : null;

  let session = readSession();
  let state = null;
  let channel = null;
  let poll = null;
  let selectedCharacter = null;
  let loading = false;

  function uid() {
    return crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const r = Math.random() * 16 | 0, v = c === 'x' ? r : (r & 0x3 | 0x8); return v.toString(16);
    });
  }

  function generateCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return Array.from({length: 6}, () => alphabet[Math.floor(Math.random()*alphabet.length)]).join('');
  }

  function escapeHtml(value='') {
    return String(value).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
  }

  function saveSession(next) {
    session = next;
    localStorage.setItem('arena_session_v1', JSON.stringify(next));
  }
  function readSession() {
    try { return JSON.parse(localStorage.getItem('arena_session_v1')) || null; } catch { return null; }
  }
  function clearSession() {
    localStorage.removeItem('arena_session_v1');
    session = null; state = null; selectedCharacter = null;
    stopSync();
  }

  function notify(message) {
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(notify.t);
    notify.t = setTimeout(() => toast.classList.remove('show'), 2600);
  }

  function setLoading(v) {
    loading = v;
    document.body.classList.toggle('loading', v);
  }

  async function rpc(name, args = {}) {
    if (!client) throw new Error('Supabase ainda não foi configurado.');
    const { data, error } = await client.rpc(name, args);
    if (error) throw new Error(error.message || 'Erro no servidor.');
    if (data && data.error) throw new Error(data.error);
    return data;
  }

  function startSync() {
    if (!client || !session?.roomId) return;
    stopSync();
    channel = client.channel(`arena:${session.roomId}`)
      .on('broadcast', { event: 'refresh' }, () => loadState(true))
      .subscribe();
    poll = setInterval(() => loadState(true), 1800);
  }
  function stopSync() {
    if (poll) clearInterval(poll);
    poll = null;
    if (channel && client) client.removeChannel(channel);
    channel = null;
  }
  async function pingRoom() {
    if (!channel) return;
    try { await channel.send({ type:'broadcast', event:'refresh', payload:{ at:Date.now() } }); } catch {}
  }

  function shell(content, roomCode = null) {
    return `
      <header class="topbar">
        <div class="brand">
          <div class="brand-mark"><span>O</span></div>
          <div class="brand-copy"><strong>O Escolhido</strong><small>disputa de personagens</small></div>
        </div>
        ${roomCode ? `<div class="room-pill">SALA <b>${escapeHtml(roomCode)}</b></div>` : ''}
      </header>
      ${content}
    `;
  }

  function renderHome() {
    stopSync();
    const configWarning = configured ? '' : `
      <div class="warning" style="margin:18px auto 0;max-width:560px">
        O site está pronto, mas o Supabase ainda não foi conectado. Preencha <b>config.js</b> e execute <b>supabase-setup.sql</b> no seu projeto antes de usar entre dispositivos.
      </div>`;
    app.innerHTML = shell(`
      <section class="hero">
        <div class="hero-card">
          <div class="eyebrow">Nove nomes. Oito destinos.</div>
          <h1>Escolha.<br>Dispute.<br>Conquiste.</h1>
          <p class="lead">Cada jogador escolhe em segredo. Quando duas vontades recaem sobre o mesmo nome, a escolha deixa de ser simples — e começa uma disputa.</p>
          <div class="actions">
            <button class="btn primary" id="createRoom">Criar sala</button>
            <button class="btn" id="joinRoom">Entrar em uma sala</button>
          </div>
          ${configWarning}
        </div>
      </section>
    `);
    document.getElementById('createRoom').onclick = () => renderCreate();
    document.getElementById('joinRoom').onclick = () => renderJoin();
  }

  function renderCreate() {
    app.innerHTML = shell(`
      <section class="form-panel">
        <div class="eyebrow">Mestre da seleção</div>
        <h2>Criar uma sala</h2>
        <p class="lead" style="text-align:left;margin-left:0">A sala comporta exatamente 8 jogadores. Você acompanha tudo como anfitrião e não ocupa uma vaga.</p>
        <div class="field"><label>Código da sala</label><input id="roomCode" maxlength="6" value="${generateCode()}" autocomplete="off"></div>
        <div class="actions" style="justify-content:flex-start">
          <button class="btn primary" id="confirmCreate">Criar</button>
          <button class="btn ghost" id="back">Voltar</button>
        </div>
      </section>
    `);
    document.getElementById('back').onclick = renderHome;
    document.getElementById('confirmCreate').onclick = createRoom;
  }

  async function createRoom() {
    if (loading) return;
    const code = document.getElementById('roomCode').value.trim().toUpperCase().replace(/[^A-Z0-9]/g,'').slice(0,6);
    if (code.length < 4) return notify('Use um código com pelo menos 4 caracteres.');
    try {
      setLoading(true);
      const hostKey = uid();
      const data = await rpc('arena_create_room', { p_code: code, p_host_key: hostKey });
      saveSession({ type:'host', roomId:data.room_id, code:data.code, key:hostKey });
      startSync();
      await loadState();
    } catch (e) { notify(e.message); }
    finally { setLoading(false); }
  }

  function renderJoin() {
    app.innerHTML = shell(`
      <section class="form-panel">
        <div class="eyebrow">Jogador</div>
        <h2>Entrar na seleção</h2>
        <div class="field"><label>Seu nome</label><input id="playerName" maxlength="30" placeholder="Como você quer aparecer?" autocomplete="off"></div>
        <div class="field"><label>Código da sala</label><input id="joinCode" maxlength="6" placeholder="EX.: A9K2LM" autocomplete="off"></div>
        <div class="actions" style="justify-content:flex-start">
          <button class="btn primary" id="confirmJoin">Entrar</button>
          <button class="btn ghost" id="back">Voltar</button>
        </div>
      </section>
    `);
    document.getElementById('back').onclick = renderHome;
    document.getElementById('confirmJoin').onclick = joinRoom;
  }

  async function joinRoom() {
    if (loading) return;
    const name = document.getElementById('playerName').value.trim();
    const code = document.getElementById('joinCode').value.trim().toUpperCase().replace(/[^A-Z0-9]/g,'');
    if (!name) return notify('Digite seu nome.');
    if (!code) return notify('Digite o código da sala.');
    try {
      setLoading(true);
      const playerKey = uid();
      const data = await rpc('arena_join_room', { p_code:code, p_name:name, p_player_key:playerKey });
      saveSession({ type:'player', roomId:data.room_id, playerId:data.player_id, code:data.code, key:playerKey });
      startSync();
      await loadState();
      await pingRoom();
    } catch (e) { notify(e.message); }
    finally { setLoading(false); }
  }

  async function loadState(silent=false) {
    if (!session?.roomId || !session?.key || !client) return;
    try {
      const data = await rpc('arena_get_state', { p_room_id:session.roomId, p_access_key:session.key });
      state = data;
      if (!silent || document.visibilityState === 'visible') renderState();
    } catch (e) {
      if (!silent) notify(e.message);
      if (/acesso|sala/i.test(e.message)) { clearSession(); renderHome(); }
    }
  }

  function playerById(id) { return state?.players?.find(p => p.id === id); }
  function myPlayer() { return session?.playerId ? playerById(session.playerId) : null; }
  function assignedNames() { return new Set((state?.players || []).map(p => p.assigned_character).filter(Boolean)); }
  function availableCharacters() { const used=assignedNames(); return CHARACTERS.filter(c => !used.has(c)); }

  function renderState() {
    if (!state?.room) return renderHome();
    const status = state.room.status;
    if (session.type === 'host') return renderHost(status);
    if (status === 'lobby') return renderPlayerLobby();
    if (status === 'selection') return renderSelection();
    if (status === 'duel') return renderDuelPhase();
    if (status === 'finished') return renderFinished(false);
  }

  function roomHeader(title, subtitle) {
    return `
      <div class="page-head">
        <div><div class="eyebrow">${escapeHtml(state.room.code)}</div><h2>${title}</h2><p>${subtitle}</p></div>
        <button class="btn ghost" id="leaveBtn">Sair</button>
      </div>`;
  }
  function bindLeave() {
    const b = document.getElementById('leaveBtn');
    if (b) b.onclick = () => { clearSession(); renderHome(); };
  }

  function renderHost(status) {
    const count = state.players.length;
    const playerRows = state.players.map((p,i) => `
      <div class="player-row"><div class="player-name"><span class="dot"></span><span>${String(i+1).padStart(2,'0')} · ${escapeHtml(p.name)}</span></div>${p.assigned_character ? `<span class="tag gold">${escapeHtml(p.assigned_character)}</span>` : '<span class="tag">aguardando</span>'}</div>`).join('');
    const logs = renderLogs();

    if (status === 'finished') return renderFinished(true);

    let main = '';
    if (status === 'lobby') {
      main = `
        <section class="panel half">
          <div class="panel-title"><h3>Convite</h3><span class="kicker">compartilhe o código</span></div>
          <div class="code-big">${escapeHtml(state.room.code)}</div>
          <div class="copy-note">Os jogadores entram pelo mesmo site e usam este código.</div>
          <div class="divider"></div>
          <button class="btn primary" id="startGame" ${count !== 8 ? 'disabled':''}>${count===8 ? 'Começar seleção' : `Aguardando ${8-count} jogador${8-count===1?'':'es'}`}</button>
        </section>`;
    } else if (status === 'selection') {
      const pct = state.room.selection_needed ? Math.round(state.room.selection_submitted/state.room.selection_needed*100) : 0;
      main = `
        <section class="panel half">
          <div class="panel-title"><h3>Escolhas secretas</h3><span class="kicker">rodada ${state.room.phase_round}</span></div>
          <div style="font:600 46px 'Cormorant Garamond',serif">${state.room.selection_submitted} / ${state.room.selection_needed}</div>
          <p class="help">Jogadores sem personagem estão escolhendo. As opções só são comparadas quando todos confirmam.</p>
          <div class="progress"><span style="width:${pct}%"></span></div>
        </section>`;
    } else if (status === 'duel') {
      main = `
        <section class="panel half">
          <div class="panel-title"><h3>Disputas em andamento</h3><span class="kicker">melhor de 3</span></div>
          <div class="conflict-list">${renderConflictSummaries()}</div>
        </section>`;
    }

    app.innerHTML = shell(`
      ${roomHeader('Sala de seleção', status==='lobby' ? 'Quando os oito nomes estiverem presentes, a escolha poderá começar.' : 'Acompanhe a distribuição sem interferir nas escolhas dos jogadores.')}
      <div class="grid">
        ${main}
        <section class="panel half"><div class="panel-title"><h3>Jogadores</h3><span class="kicker">${count}/8</span></div><div class="player-list">${playerRows || '<p class="help">Ninguém entrou ainda.</p>'}</div></section>
        <section class="panel"><div class="panel-title"><h3>Registro</h3><span class="kicker">acontecimentos</span></div>${logs}</section>
      </div>
    `, state.room.code);
    bindLeave();
    const start = document.getElementById('startGame');
    if (start) start.onclick = startGame;
  }

  async function startGame() {
    try {
      setLoading(true);
      await rpc('arena_start_game', { p_room_id:session.roomId, p_host_key:session.key });
      await pingRoom(); await loadState();
    } catch(e) { notify(e.message); } finally { setLoading(false); }
  }

  function renderPlayerLobby() {
    const p = myPlayer();
    app.innerHTML = shell(`
      ${roomHeader('A espera começou.', 'Você entrou na seleção. Quando oito jogadores estiverem presentes, o anfitrião poderá iniciar.')}
      <section class="panel">
        <div class="center-state">
          <div class="sigil"><span>${escapeHtml((p?.name||'?')[0].toUpperCase())}</span></div>
          <h3>${escapeHtml(p?.name || '')}</h3>
          <p>${state.players.length} de 8 jogadores conectados à sala.</p>
          <div class="progress" style="max-width:420px;margin:18px auto 0"><span style="width:${state.players.length/8*100}%"></span></div>
        </div>
      </section>
    `, state.room.code);
    bindLeave();
  }

  function renderSelection() {
    const me = myPlayer();
    if (!me) return;
    if (me.assigned_character) return renderOwnedWaiting(me.assigned_character, 'Enquanto outras disputas são resolvidas, seu personagem já está garantido.');
    if (state.viewer.has_selection) return renderLockedChoice();

    const available = availableCharacters();
    const cards = CHARACTERS.map((name,i) => {
      const locked = !available.includes(name);
      const selected = selectedCharacter === name;
      return `<article class="char-card ${locked?'locked':''} ${selected?'selected':''}" data-char="${escapeHtml(name)}">
        <span class="char-index">PERSONAGEM ${String(i+1).padStart(2,'0')}</span>
        <span class="char-symbol">${escapeHtml(name[0])}</span>
        <div><h3>${escapeHtml(name)}</h3><p>${locked ? 'Já possui um jogador.' : 'Disponível para escolha.'}</p></div>
        <span class="char-picked">${selected ? 'Sua escolha' : locked ? 'Indisponível' : 'Selecionar'}</span>
      </article>`;
    }).join('');

    app.innerHTML = shell(`
      ${roomHeader('Quem você escolhe?', 'Sua escolha é secreta. Se outra pessoa escolher o mesmo nome, vocês precisarão disputá-lo.')}
      <section class="panel">
        <div class="panel-title"><h3>Personagens disponíveis</h3><span class="kicker">rodada ${state.room.phase_round}</span></div>
        <div class="character-grid">${cards}</div>
        <div class="actions" style="margin-top:20px;justify-content:flex-end">
          <button class="btn primary" id="confirmCharacter" ${selectedCharacter ? '' : 'disabled'}>${selectedCharacter ? `Confirmar ${escapeHtml(selectedCharacter)}` : 'Escolha um personagem'}</button>
        </div>
      </section>
    `, state.room.code);
    bindLeave();
    document.querySelectorAll('.char-card:not(.locked)').forEach(card => card.onclick = () => {
      selectedCharacter = card.dataset.char; renderSelection();
    });
    document.getElementById('confirmCharacter').onclick = submitSelection;
  }

  async function submitSelection() {
    if (!selectedCharacter || loading) return;
    try {
      setLoading(true);
      await rpc('arena_submit_selection', {
        p_room_id:session.roomId, p_player_id:session.playerId, p_player_key:session.key, p_character:selectedCharacter
      });
      selectedCharacter = null;
      await pingRoom(); await loadState();
    } catch(e) { notify(e.message); } finally { setLoading(false); }
  }

  function renderLockedChoice() {
    app.innerHTML = shell(`
      ${roomHeader('Escolha selada.', 'Ninguém verá sua escolha antes de todos os jogadores desta rodada confirmarem.')}
      <section class="panel"><div class="center-state"><div class="sigil"><span>✦</span></div><h3>Aguardando os outros</h3><p>${state.room.selection_submitted} de ${state.room.selection_needed} escolhas foram confirmadas.</p><div class="progress" style="max-width:430px;margin:18px auto 0"><span style="width:${state.room.selection_needed ? state.room.selection_submitted/state.room.selection_needed*100 : 0}%"></span></div></div></section>
    `, state.room.code);
    bindLeave();
  }

  function renderOwnedWaiting(character, text) {
    app.innerHTML = shell(`
      ${roomHeader('Você conquistou seu personagem.', text)}
      <section class="panel"><div class="center-state"><div class="sigil"><span>${escapeHtml(character[0])}</span></div><div class="eyebrow">Seu personagem</div><h2 style="margin-top:10px">${escapeHtml(character)}</h2><p>Aguarde até que todos os outros jogadores também tenham um destino.</p></div></section>
    `, state.room.code);
    bindLeave();
  }

  function renderDuelPhase() {
    const me = myPlayer();
    if (!me) return;
    if (me.assigned_character) return renderOwnedWaiting(me.assigned_character, 'Outras pessoas ainda estão disputando seus personagens.');

    const relevant = (state.conflicts || []).find(c =>
      c.status === 'active' && (c.champion_id === me.id || c.current_opponent_id === me.id || (c.waiting_ids || []).includes(me.id))
    );
    if (!relevant) {
      app.innerHTML = shell(`
        ${roomHeader('A disputa continua.', 'Você não está em um duelo ativo neste instante.')}
        <section class="panel"><div class="center-state"><div class="sigil"><span>…</span></div><h3>Aguarde o desfecho</h3><p>Assim que as disputas desta rodada terminarem, você poderá escolher novamente entre os personagens restantes.</p></div></section>
      `, state.room.code); bindLeave(); return;
    }
    if ((relevant.waiting_ids || []).includes(me.id)) {
      const pos = relevant.waiting_ids.indexOf(me.id)+1;
      app.innerHTML = shell(`
        ${roomHeader(`Disputa por ${escapeHtml(relevant.character)}`, 'Mais de duas pessoas escolheram o mesmo personagem. O torneio acontece em sequência.')}
        <section class="panel"><div class="center-state"><div class="sigil"><span>${pos}</span></div><h3>Você está na fila do duelo.</h3><p>Se o vencedor atual sobreviver, enfrentará o próximo desafiante. Sua posição na fila: ${pos}.</p></div></section>
      `, state.room.code); bindLeave(); return;
    }
    return renderActiveDuel(relevant);
  }

  function renderActiveDuel(c) {
    const a = playerById(c.champion_id), b = playerById(c.current_opponent_id);
    const me = myPlayer();
    const submitted = !!c.viewer_submitted;
    const scoreDots = n => `<div class="score"><i class="${n>0?'on':''}"></i><i class="${n>1?'on':''}"></i></div>`;
    const moves = Object.entries(MOVES).map(([key,m]) => `<button class="move" data-move="${key}" ${submitted?'disabled':''}><b>${m.label}</b><span>${m.hint}</span></button>`).join('');
    app.innerHTML = shell(`
      ${roomHeader(`Disputa por ${escapeHtml(c.character)}`, 'Cada decisão é secreta. O primeiro a vencer dois rounds conquista o personagem.')}
      <section class="panel">
        <div class="duel-wrap">
          <div class="fighter"><div class="initial">${escapeHtml((a?.name||'?')[0])}</div><h3>${escapeHtml(a?.name||'—')}</h3>${scoreDots(c.champion_score)}</div>
          <div class="vs">VS</div>
          <div class="fighter"><div class="initial">${escapeHtml((b?.name||'?')[0])}</div><h3>${escapeHtml(b?.name||'—')}</h3>${scoreDots(c.opponent_score)}</div>
        </div>
        <div style="text-align:center;margin-top:24px"><span class="tag gold">ROUND ${c.duel_round}</span></div>
        ${submitted ? `<div class="center-state" style="padding:30px 20px 10px"><h3>Escolha registrada.</h3><p>Esperando ${escapeHtml((me.id===a?.id?b:a)?.name || 'o oponente')} decidir.</p></div>` : `<div class="move-grid">${moves}</div>`}
        <div class="rule-strip"><span>ATAQUE vence TRUQUE</span><span>TRUQUE vence DEFESA</span><span>DEFESA vence ATAQUE</span></div>
      </section>
      <section class="panel" style="margin-top:16px"><div class="panel-title"><h3>Últimos acontecimentos</h3><span class="kicker">duelo</span></div>${renderLogs(6)}</section>
    `, state.room.code);
    bindLeave();
    document.querySelectorAll('.move').forEach(btn => btn.onclick = () => submitMove(c.id, btn.dataset.move));
  }

  async function submitMove(conflictId, move) {
    if (loading) return;
    try {
      setLoading(true);
      const result = await rpc('arena_submit_move', {
        p_conflict_id:conflictId, p_player_id:session.playerId, p_player_key:session.key, p_move:move
      });
      if (result?.message) notify(result.message);
      await pingRoom(); await loadState();
    } catch(e) { notify(e.message); } finally { setLoading(false); }
  }

  function renderConflictSummaries() {
    const active = (state.conflicts || []).filter(c=>c.status==='active');
    if (!active.length) return '<p class="help">Nenhuma disputa ativa.</p>';
    return active.map(c => {
      const a=playerById(c.champion_id), b=playerById(c.current_opponent_id);
      return `<div class="conflict"><div><b>${escapeHtml(c.character)}</b><small>${escapeHtml(a?.name||'—')} ${c.champion_score} × ${c.opponent_score} ${escapeHtml(b?.name||'—')} · round ${c.duel_round}</small></div><span class="tag">+${(c.waiting_ids||[]).length} na fila</span></div>`;
    }).join('');
  }

  function renderLogs(limit=20) {
    const logs = (state.logs || []).slice(0,limit);
    return `<div class="log">${logs.length ? logs.map(l=>`<div class="log-entry">${escapeHtml(l.message)}</div>`).join('') : '<div class="log-entry">A história desta sala ainda está em branco.</div>'}</div>`;
  }

  function renderFinished(isHost) {
    const sorted = [...state.players].sort((a,b)=>a.name.localeCompare(b.name));
    const used = assignedNames();
    const left = CHARACTERS.find(c=>!used.has(c)) || '—';
    const cards = sorted.map(p=>`<div class="result-card"><strong>${escapeHtml(p.name)}</strong><span>ficou com ${escapeHtml(p.assigned_character || '—')}</span></div>`).join('');
    app.innerHTML = shell(`
      ${roomHeader('Oito foram escolhidos.', 'A seleção terminou. Um nome permaneceu sem dono.')}
      <section class="panel">
        <div class="panel-title"><h3>Resultado final</h3><span class="kicker">8 jogadores · 9 personagens</span></div>
        <div class="result-grid">${cards}<div class="result-card left-out"><strong>${escapeHtml(left)}</strong><span>ficou de fora</span></div></div>
      </section>
      ${isHost ? `<section class="panel" style="margin-top:16px"><div class="panel-title"><h3>Registro final</h3><span class="kicker">histórico</span></div>${renderLogs(40)}</section>` : ''}
    `, state.room.code);
    bindLeave();
  }

  // Inicialização
  if (!configured) {
    renderHome();
  } else if (session?.roomId && session?.key) {
    startSync();
    loadState().catch(renderHome);
  } else {
    renderHome();
  }
})();
