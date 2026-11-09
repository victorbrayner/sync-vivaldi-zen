# sync-vivaldi-zen — Abas do Vivaldi → Zen

Exporte um snapshot somente leitura das abas abertas no **Vivaldi (Windows)** para consultar rapidamente no **Zen Browser (macOS)** — ou em qualquer outro navegador — usando o **Syncthing** como transporte.

Nada de conta na nuvem, servidor externo ou abas "materializadas" automaticamente: a outra máquina recebe uma fotografia local do que está aberto no desktop e você decide o que abrir, com um clique.

## Por que este projeto existe?

Quem alterna entre o **Vivaldi no Windows** (com uso pesado de *Tab Stacks*) e o **Zen no macOS** não tem uma forma nativa de sincronizar abas entre os dois navegadores. As extensões de sessão costumam exigir serviços de terceiros ou abrem dezenas de abas de uma vez no navegador de destino.

Este projeto resolve isso de forma local e minimalista:

```
┌──────────────── Windows ────────────────┐        ┌───────── macOS / Outro ─────────┐
│ Vivaldi                                 │        │ Zen (ou qualquer navegador)     │
│   extensão  ──HTTP 127.0.0.1──▶ agente  │        │   index.html (aba fixada)       │
│                                   │     │        │        ▲                        │
│                                   ▼     │        │        │                        │
│                         pasta sincronizada ─────▶ pasta sincronizada               │
│                         (Send Only)     │ Syncthing (Receive Only)                 │
└─────────────────────────────────────────┘        └─────────────────────────────────┘
```

> **Compatibilidade:** Embora desenhado para o fluxo *Vivaldi (Windows) → Zen (macOS) via Syncthing*, a página gerada (`index.html`) é um arquivo estático sem dependências que funciona em **qualquer navegador e sistema operacional**, e a pasta pode ser sincronizada por qualquer ferramenta de arquivos (Syncthing, Dropbox, OneDrive, iCloud Drive, compartilhamento de rede etc.).

## Funcionalidades

- **Janelas e ordem preservadas:** lista todas as janelas normais do perfil do Vivaldi na mesma ordem do navegador.
- **Metadados completos:** título, favicon, domínio, indicador de abas **fixadas**, aba **ativa** e janela **Em foco**.
- **Suporte a Tab Stacks do Vivaldi:** agrupa abas empilhadas (e grupos nativos do Chromium) de forma colapsável, com nome, contagem e botão **Abrir tudo**.
- **Busca instantânea:** filtro em tempo real por título ou URL, atalho <kbd>/</kbd> para focar na busca e botão para copiar URL.
- **Tema claro e escuro:** segue automaticamente a preferência do sistema (`prefers-color-scheme`), sem dependências externas.
- **Indicador de estado do desktop:** mostra se o snapshot está **atualizado**, se o **Vivaldi está fechado/inativo** ou se o **desktop está desconectado**, mantendo sempre o último snapshot disponível para consulta offline.
- **Baixo ruído de sincronização:** o agente calcula o hash SHA-256 do snapshot (ignorando o timestamp) e só reescreve `tabs.json` / `tabs-data.js` quando as abas realmente mudam.

**O que fica de fora de propósito:** janelas privadas/incógnito, páginas internas (`vivaldi://`, `chrome://`, `about:`) e Workspaces. O fluxo é **estritamente unidirecional e somente leitura**: o dispositivo de leitura nunca altera nada no Windows.

## Estrutura do repositório

```text
extension/                 Extensão Manifest V3 para o Vivaldi
  manifest.json
  background.js
agent/                     Agente local para Windows (PowerShell 5.1)
  agent.ps1                Servidor HTTP em loopback (127.0.0.1) + escrita atômica
  config.json              Configuração padrão do agente
  install-agent.ps1        Instalador/removedor da tarefa agendada no Windows
  run-agent.bat            Execução manual em janela para testes e depuração
  index.template.html      Template single-file copiado como index.html
README.md
```

### Arquivos gerados na pasta compartilhada

| Arquivo | Papel |
|---|---|
| `index.html` | Página de visualização autocontida (cópia de `index.template.html`) |
| `tabs.json` | Snapshot bruto em JSON (útil para inspeção/depuração) |
| `tabs-data.js` | Mesmo snapshot exposto em `window.__VIVALDI_TABS__` para funcionar via `file://` |
| `heartbeat.json` | Estado e timestamps do agente e da extensão |
| `heartbeat.js` | Mesmo heartbeat exposto em `window.__VIVALDI_HEARTBEAT__` |

O agente publica `index.html` ao iniciar e atualiza o heartbeat a cada 60 segundos. A extensão envia snapshots a cada mudança nas abas (com *debounce* de 1,5 s) e um pulso a cada 1 minuto. A página recarrega os scripts de dados a cada 15 segundos sem *reload* completo, preservando o texto buscado e os grupos abertos/fechados no `localStorage`.

## Requisitos

- **Origem:** Windows 10 ou 11 com [Vivaldi](https://vivaldi.com/) e Windows PowerShell 5.1 (nativo do sistema — não requer Node, Python nem privilégios de administrador).
- **Destino:** macOS (ou outro SO) com [Zen Browser](https://zen-browser.app/) (ou qualquer navegador moderno).
- **Transporte:** [Syncthing](https://syncthing.net/) configurado nos dois dispositivos (ou outro sincronizador de pastas).

---

## Guia de instalação

### 1. Preparar a pasta no Syncthing

1. No Windows, crie uma pasta dedicada **fora** deste repositório, por exemplo:
   `C:\Users\SEU_USUARIO\Syncthing\vivaldi-tabs`
2. Adicione essa pasta no Syncthing e compartilhe com o Mac.
3. No Mac, aceite o compartilhamento e aponte para um caminho local, por exemplo `~/Syncthing/vivaldi-tabs`.
4. Recomendações de configuração da pasta no Syncthing:
   - **Tipo de pasta no Windows:** *Send Only* (Apenas Envio)
   - **Tipo de pasta no Mac:** *Receive Only* (Apenas Recebimento)
   - **Avançado:** ative **Ignore Permissions** (*Ignorar Permissões*) nos dois lados
   - **Versionamento de arquivos:** desativado (desnecessário para snapshots efêmeros)

Com apenas o Windows escrevendo, você evita conflitos (`sync-conflict-*`). **Importante:** sincronize apenas essa pasta de saída, nunca a pasta de perfil do Vivaldi.

### 2. Instalar o agente no Windows

1. Clone este repositório (ou baixe o ZIP) no Windows em um caminho fixo, por exemplo `C:\Tools\sync-vivaldi-zen`:
   ```powershell
   git clone https://github.com/SEU_USUARIO/sync-vivaldi-zen.git C:\Tools\sync-vivaldi-zen
   ```
2. Revise o arquivo `agent\config.json`:

   ```json
   {
     "port": 8765,
     "outputDir": "%USERPROFILE%\\Syncthing\\vivaldi-tabs",
     "deviceName": "desktop-windows",
     "heartbeatSeconds": 60
   }
   ```

   - `outputDir`: caminho da pasta compartilhada criada no passo 1. Variáveis de ambiente como `%USERPROFILE%` são expandidas automaticamente.
   - `deviceName`: identificação da máquina exibida no topo da página.
   - `port`: porta local em `127.0.0.1` (se alterar aqui, altere também `CONFIG.endpoint` em `extension/background.js`).

3. Abra o PowerShell dentro da pasta `agent` e registre a tarefa agendada:

   ```powershell
   cd C:\Tools\sync-vivaldi-zen\agent
   powershell -ExecutionPolicy Bypass -File .\install-agent.ps1
   ```

   Isso cria e inicia a tarefa agendada **VivaldiTabsAgent**, configurada para rodar em segundo plano no logon do seu usuário (sem precisar de administrador, pois usa `TcpListener` em `127.0.0.1` em vez de `HttpListener`).

4. Verifique se o agente respondeu e gerou os arquivos iniciais:

   ```powershell
   Invoke-RestMethod http://127.0.0.1:8765/health
   Get-Content .\agent.log -Tail 20
   ```

   Os arquivos `index.html`, `heartbeat.json` e `heartbeat.js` já devem aparecer na pasta compartilhada.

   > **Dica:** Para testar manualmente vendo os logs em tempo real no terminal, execute `run-agent.bat`. Para desinstalar a tarefa agendada no futuro:
   > ```powershell
   > powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -Uninstall
   > ```

### 3. Instalar a extensão no Vivaldi (Windows)

1. No Vivaldi, abra `vivaldi://extensions`.
2. Ative a chave **Modo do desenvolvedor** (canto superior direito).
3. Clique em **Carregar sem compactação** (*Load unpacked*) e selecione a pasta `extension/` deste repositório.
4. Com o agente rodando, o ícone da extensão não deve exibir o aviso `!`. Você pode clicar no ícone da extensão a qualquer momento para forçar o envio imediato de um snapshot.

### 4. Usar no Zen (macOS)

1. Aguarde o Syncthing sincronizar `index.html` e `tabs-data.js` na pasta do Mac.
2. Abra o arquivo `index.html` no Zen (arraste para o navegador ou abra via `Cmd + O`).
3. Fixe a aba (**Fixar aba** / *Pin Tab*) ou adicione aos Essential Tabs do Zen para tê-la sempre à mão.
4. Na primeira vez que clicar em **Abrir tudo** em um *Tab Stack*, o navegador pode bloquear a abertura de múltiplas abas. Permita pop-ups para a página local (`file://`) na barra de endereços e clique novamente.

---

## Como funciona por baixo dos panos

- **Leitura de Tab Stacks no Vivaldi:** o Vivaldi não possui uma API pública oficial para *Tab Stacks*. A extensão combina `chrome.windows.getAll`, `chrome.tabs.query`, `chrome.tabGroups` e os metadados internos `tab.vivExtData` / `TAB_STACKING_NAME_MAP` em `chrome.storage.local` para reconstruir os agrupamentos e seus nomes.
- **Atualização sem servidor web no destino:** navegadores modernos bloqueiam `fetch()` para arquivos locais em `file://` por políticas de CORS. Para contornar isso sem exigir um servidor HTTP no Mac, o agente grava os dados também como scripts JS (`tabs-data.js` e `heartbeat.js`) e o `index.html` reinjeta tags `<script>` com *cache-busting* a cada 15 segundos.
- **Escrita atômica:** todos os arquivos gerados pelo agente são gravados primeiro em um arquivo temporário (`.tmp-*.part`) na mesma pasta e movidos com `Move-Item -Force`, evitando que o Syncthing sincronize arquivos truncados ou pela metade.

## Privacidade e segurança

- **Apenas loopback:** o agente escuta exclusivamente em `127.0.0.1` e não fica exposto na rede local.
- **Filtro na origem:** janelas anônimas/privadas e esquemas internos são ignorados antes mesmo de sair da extensão.
- **Dados em texto puro no disco:** os arquivos `tabs.json` e `tabs-data.js` contêm títulos e URLs completas (incluindo *query strings*). O Syncthing criptografa o tráfego em trânsito entre seus dispositivos, mas os arquivos residem em texto puro nas pastas locais.
- **Nunca faça commit da pasta de saída:** mantenha `outputDir` fora do repositório Git para não publicar acidentalmente seu histórico de abas abertas.

## Solução de problemas

<details>
<summary><strong>O ícone da extensão mostra <code>!</code> em vermelho</strong></summary>

A extensão não conseguiu conectar ao agente local:
1. Verifique se o agente está ativo: `Invoke-RestMethod http://127.0.0.1:8765/health`
2. Confirme se a porta em `agent/config.json` é a mesma definida em `extension/background.js` (`CONFIG.endpoint`).
3. Consulte os últimos eventos em `agent/agent.log`.
4. Reinicie a tarefa agendada: `Restart-ScheduledTask -TaskName VivaldiTabsAgent`
</details>

<details>
<summary><strong>A página mostra "Vivaldi fechado ou inativo" com o Vivaldi aberto</strong></summary>

O agente está rodando no Windows, mas não recebe atualizações da extensão há mais de 3 minutos. Verifique se a extensão está ativada em `vivaldi://extensions` e inspecione o console do *service worker* da extensão para checar possíveis erros.
</details>

<details>
<summary><strong>A página mostra "Desktop desconectado"</strong></summary>

O heartbeat sincronizado tem mais de 3 minutos. Isso é esperado quando o PC Windows está desligado/suspenso ou quando o Syncthing ainda está conectando. O último snapshot recebido permanece navegável normalmente.
</details>

<details>
<summary><strong>Os Tab Stacks não aparecem agrupados</strong></summary>

Como o Vivaldi armazena stacks no campo interno `vivExtData`, uma atualização futura do navegador pode alterar esse formato. Caso isso aconteça, as abas continuarão sendo listadas normalmente na janela, apenas desagrupadas.
</details>

<details>
<summary><strong>"Abrir tudo" abre apenas a primeira aba do stack</strong></summary>

Isso é o bloqueador de pop-ups do navegador de destino. Autorize pop-ups para o endereço `file://` da página e tente novamente.
</details>

<details>
<summary><strong>Arquivos <code>sync-conflict-*</code> aparecem na pasta</strong></summary>

Certifique-se de que a pasta no Syncthing está em modo *Send Only* no Windows e *Receive Only* no Mac. Se o Mac exibir o botão *Revert Local Additions* no Syncthing, clique nele para restaurar o estado oficial vindo do Windows.
</details>

## Limitações conhecidas

- Fluxo unidirecional (Windows → Mac) e somente leitura.
- Exporta apenas janelas normais do perfil onde a extensão está instalada; *Workspaces* do Vivaldi não são separados na visualização.
- Páginas internas do navegador (`vivaldi://`, `chrome://`, `about:`) são omitidas pois não abririam em outro navegador.
- Atualizações de código exigem `git pull` (ou cópia manual), clicar em **Recarregar** na extensão em `vivaldi://extensions` e reiniciar a tarefa `VivaldiTabsAgent` se o `agent.ps1` ou `index.template.html` tiverem mudado.

## Licença

Distribuído sob a licença MIT. Sinta-se à vontade para fazer *fork* e adaptar para o seu próprio fluxo entre navegadores.
