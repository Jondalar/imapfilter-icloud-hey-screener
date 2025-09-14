# IMAP Screener for iCloud (imapfilter + Docker)

This project provides a self-hosted alternative to services like **HEY.com Screener** or **Sanebox**, but built entirely with [imapfilter](https://github.com/lefcha/imapfilter) inside Docker.  
It was developed specifically for **iCloud Mail**, but should work with any IMAP account.

---

## ✨ Features

- **Server-side style screening**:  
  All new mails are moved by an iCloud rule directly into a `Screened/` folder (so you don’t get push notifications for unknown senders).  
- **Whitelist / Approve**:  
  When you move a mail from `Screened/` → `INBOX`, the sender is added to a permanent `whitelist.txt`. Future mails from them bypass `Screened` and land directly in INBOX.  
- **Blocklist**:  
  Move a mail to `Blackhole/` → sender goes to `blocklist.txt`. They’ll be filtered forever.  
- **Receipts / Newsletters**:  
  Training folders. Move mails there once → sender is remembered. Future mails go there automatically.  
- **Persistent state**:  
  Lists are stored in plain text under `/state` (`whitelist.txt`, `blocklist.txt`, `receiptlist.txt`, `newsletterlist.txt`, `screened_ids.txt`).  
- **Dockerized**:  
  Easy to deploy on a NAS or Linux host.

---

## 📦 Requirements

- A server/NAS with Docker + docker-compose (tested on QNAP with Docker via Warp shell).  
- An [iCloud app-specific password](https://support.apple.com/en-us/HT204397).  
- IMAP enabled for your account.  
- iCloud Mail **server-side rules** (via [icloud.com → Mail → Settings → Rules]) to move **all incoming mail into `Screened/`**.

---

## 🚀 Setup

### 1. Clone & Prepare
```bash
git clone https://github.com/YOURUSER/imap-screener.git
cd imap-screener
```

Project structure:
```
imap-screener/
 ├─ docker-compose.yml
 ├─ Dockerfile
 ├─ imapfilter/
 │   ├─ config.lua        # main imapfilter config
 │   └─ run.sh            # run loop wrapper
 └─ state/                # persistent lists
```

### 2. Configure Environment
Edit `docker-compose.yml`:

```yaml
services:
  imapfilter:
    build: .
    container_name: imapfilter
    restart: unless-stopped
    environment:
      - TZ=Europe/Berlin
      - IMAP_PW=your_app_specific_password
    volumes:
      - ./imapfilter:/config
      - ./state:/state
    entrypoint: ["/bin/sh", "/config/run.sh"]
```

Set your actual iCloud email in `config.lua`:
```lua
username = 'alex.damhuis@icloud.com'
```

### 3. Run
```bash
docker compose build --no-cache
docker compose up -d
docker logs -f imapfilter
```

You should see logs like:
```
--- 2025-09-14 10:15:00 START ---
Fetched the header of .../Screened[1]
...
--- 2025-09-14 10:15:02 END ---
```

---

## 📂 Workflow

- **New mail** → iCloud server rule puts it in `Screened/`.  
- **imapfilter loop (every 60s or 600s)** sorts:
  - Whitelist → INBOX
  - Blocklist → Blackhole
  - Receipts → Receipts
  - Newsletters → Newsletters
  - Others stay in `Screened/`

- **Training / approving**:
  - Move mail → INBOX (approve) → sender whitelisted.  
  - Move mail → Blackhole → sender blocked.  
  - Move mail → Receipts → sender added to receipt list.  
  - Move mail → Newsletters → sender added to newsletter list.  

All lists are permanent (plain text files in `./state`).

---

## 🔧 Customization

- Change scan interval in `imapfilter/run.sh`:
  ```sh
  SLEEP=600   # seconds
  ```
- Add more keyword heuristics (e.g. for receipts) in `config.lua`.  
- Edit list files manually in `./state/*.txt`.

---

## 📝 Example State Files

`whitelist.txt`:
```
friend@example.com
*@trusted-domain.com
```

`blocklist.txt`:
```
spam@bad-domain.com
*@junkmail.org
```

---

## ⚠️ Limitations

- Push notifications: iCloud still triggers push if the mail first lands in INBOX. That’s why you must use **iCloud server rules** to redirect everything into `Screened/`.  
- imapfilter runs in a polling loop (default 600s). It’s not event-based.  

---

## 💡 Credits

- Built with [imapfilter](https://github.com/lefcha/imapfilter).  
- Inspired by HEY.com Screener and Sanebox.  
- Docker setup tested on QNAP NAS (Warp shell).
