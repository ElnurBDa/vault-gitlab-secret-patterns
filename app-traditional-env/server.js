const express = require('express');
const app = express();
const PORT = 80;

const USERNAME = process.env.USERNAME || '(not set)';
const PASSWORD = process.env.PASSWORD || '(not set)';

app.get('/', (req, res) => {
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Env Debug</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      background: #0d0d0d;
      color: #e0e0e0;
      font-family: 'Courier New', monospace;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
    }

    .terminal {
      width: 100%;
      max-width: 600px;
      border: 1px solid #2a2a2a;
      border-radius: 8px;
      overflow: hidden;
      box-shadow: 0 0 40px rgba(0,255,136,0.05);
    }

    .titlebar {
      background: #1a1a1a;
      padding: 0.6rem 1rem;
      display: flex;
      align-items: center;
      gap: 0.5rem;
      border-bottom: 1px solid #2a2a2a;
    }

    .dot { width: 12px; height: 12px; border-radius: 50%; }
    .dot.red    { background: #ff5f57; }
    .dot.yellow { background: #febc2e; }
    .dot.green  { background: #28c840; }

    .titlebar span {
      margin-left: auto;
      font-size: 0.75rem;
      color: #555;
      letter-spacing: 0.05em;
    }

    .body {
      background: #111;
      padding: 1.8rem 2rem;
    }

    .prompt {
      color: #00ff88;
      font-size: 0.8rem;
      margin-bottom: 1.5rem;
      letter-spacing: 0.03em;
    }

    .row {
      display: flex;
      align-items: baseline;
      gap: 1rem;
      padding: 0.75rem 0;
      border-bottom: 1px solid #1e1e1e;
    }

    .row:last-child { border-bottom: none; }

    .label {
      color: #555;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      min-width: 100px;
      flex-shrink: 0;
    }

    .value {
      color: #f0f0f0;
      font-size: 0.95rem;
      word-break: break-all;
    }

    .value.unset { color: #ff5f57; font-style: italic; }

    .footer {
      padding: 1rem 2rem;
      background: #0d0d0d;
      border-top: 1px solid #1e1e1e;
      font-size: 0.7rem;
      color: #333;
      display: flex;
      justify-content: space-between;
    }
  </style>
</head>
<body>
  <div class="terminal">
    <div class="titlebar">
      <div class="dot red"></div>
      <div class="dot yellow"></div>
      <div class="dot green"></div>
      <span>env-debug · port ${PORT}</span>
    </div>
    <div class="body">
      <div class="prompt">$ printenv | grep -E 'USERNAME|PASSWORD'</div>
      <div class="row">
        <span class="label">USERNAME</span>
        <span class="value ${USERNAME === '(not set)' ? 'unset' : ''}">${USERNAME}</span>
      </div>
      <div class="row">
        <span class="label">PASSWORD</span>
        <span class="value ${PASSWORD === '(not set)' ? 'unset' : ''}">${PASSWORD}</span>
      </div>
    </div>
    <div class="footer">
      <span>node ${process.version}</span>
      <span>${new Date().toISOString()}</span>
    </div>
  </div>
</body>
</html>`);
});

app.listen(PORT, () => {
  console.log(`Listening on :${PORT}`);
  console.log(`USERNAME=${USERNAME}`);
  console.log(`PASSWORD=${PASSWORD}`);
});
