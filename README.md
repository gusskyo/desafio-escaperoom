# O Escolhido — seleção online de personagens

Site multiplayer para 8 jogadores disputarem 9 personagens:

- Emeline
- Ulisses
- Toni
- Anni
- Alex
- Rafael
- Julie
- Kendi
- Chiara

## Como funciona

1. O anfitrião cria uma sala e recebe um código.
2. 8 jogadores entram pelo código.
3. Todos os jogadores sem personagem escolhem secretamente.
4. Escolhas únicas são conquistadas automaticamente.
5. Se 2+ jogadores escolherem o mesmo personagem, começa um torneio.
6. Cada duelo é melhor de 3 usando:
   - ATAQUE vence TRUQUE
   - TRUQUE vence DEFESA
   - DEFESA vence ATAQUE
7. Quem perde volta para uma nova rodada de escolha.
8. Ao final, 8 personagens têm dono e 1 fica de fora.

## 1. Criar o backend

Crie um projeto gratuito no Supabase.

Abra **SQL Editor > New query**, cole todo o conteúdo de `supabase-setup.sql` e execute.

## 2. Conectar o site

No Supabase, copie:

- Project URL
- Publishable key (ou anon key em projetos antigos)

Abra `config.js` e substitua os dois placeholders.

## 3. Publicar

É um site estático. Você pode publicar a pasta inteira no Netlify, Vercel, GitHub Pages ou outro host estático.

No Netlify, por exemplo, basta arrastar a pasta do site já configurada para o deploy manual.

## Teste local

Como o navegador pode bloquear alguns recursos ao abrir `index.html` diretamente, rode um servidor local na pasta:

```bash
python -m http.server 8080
```

Depois abra `http://localhost:8080`.

## Observações

- O anfitrião não ocupa uma das 8 vagas.
- A identidade do jogador e do anfitrião é guardada localmente no navegador.
- As escolhas e movimentos secretos não são lidos diretamente pelo navegador; o frontend usa funções RPC no Supabase.
- O site usa Supabase Realtime Broadcast para acelerar atualizações e também possui polling como fallback.
