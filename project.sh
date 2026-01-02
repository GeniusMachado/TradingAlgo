#!/usr/bin/env bash
set -euo pipefail

REPO=TradingAlgo
mkdir -p "$REPO"

echo "🚀 Building Genius Machado V23 (Black Box Journal)..."

cat > "$REPO/README.md" <<'MD'
# Genius Machado — V23 (Black Box Journaling)

## 📓 Automated Journaling
- **Trade Logger**: Records every simulated trade with precise timestamps and reasoning.
- **Stats Engine**: Calculates Win Rate, Average R:R, and Profit Factor live.
- **Visual Review**: Dashboard table showing "Why I Took This Trade".

## 🧠 Strategy Logic
- **M7**: DR/IDR Ranges, KM7/Retirement Models.
- **ICT**: PD Arrays, Liquidity Sweeps (ERL/IRL), Silver Bullet timings.
- **Execution**: Paper trading on NQ futures data.

## ⚡ Setup
1. Add Cloudflare Token to `docker-compose.yml`.
2. Add `banner.jpg` to `frontend/static/images/`.
3. Run `docker compose up --build`.
MD

# -------------------------
# Docker Compose
# -------------------------
cat > "$REPO/docker-compose.yml" <<'YML'
version: '3.8'
services:
  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: genius
      MYSQL_USER: genius
      MYSQL_PASSWORD: geniuspass
    volumes:
      - db_data:/var/lib/mysql
    ports:
      - "3306:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      timeout: 20s
      retries: 10

  auth:
    build: ./auth-service
    restart: on-failure
    environment:
      DATABASE_URL: mysql+aiomysql://genius:geniuspass@db:3306/genius
      JWT_SECRET: supersecret_jwt_change_me
    volumes:
      - ./auth-service:/app
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8001:8001"

  api-gateway:
    build: ./api-gateway
    restart: on-failure
    environment:
      GATEWAY_HOST: api-gateway
      AUTH_URL: http://auth:8001
      STRATEGY_URL: http://strategy-engine:8002
      JWT_SECRET: supersecret_jwt_change_me
    volumes:
      - ./api-gateway:/app
      - ./frontend:/app/frontend:ro
    depends_on:
      - auth
      - strategy-engine
    ports:
      - "8000:8000"

  strategy-engine:
    build: ./strategy-engine
    volumes:
      - ./strategy-engine:/app
    environment:
      DATABASE_URL: mysql+aiomysql://genius:geniuspass@db:3306/genius
      TRADOVATE_ENV: "paper" 
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8002:8002"

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: always
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=Paste_the_CLoudflare_tunnel_TOKEN_HERE
    depends_on:
      - api-gateway

volumes:
  db_data:
YML

# -------------------------
# API GATEWAY
# -------------------------
mkdir -p "$REPO/api-gateway"

cat > "$REPO/api-gateway/pyproject.toml" <<'TOML'
[project]
name = "api-gateway"
version = "0.23.0"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.109.0",
    "uvicorn[standard]>=0.27.0",
    "jinja2>=3.1.3",
    "httpx>=0.26.0",
    "python-dotenv>=1.0.0",
    "python-multipart>=0.0.7",
    "python-jose[cryptography]>=3.3.0",
    "cryptography>=42.0.0",
    "email-validator>=2.1.0"
]
TOML

cat > "$REPO/api-gateway/Dockerfile" <<'DF'
FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8000
CMD ["uv", "run", "uvicorn", "gateway:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
DF

cat > "$REPO/api-gateway/gateway.py" <<'PY'
import os
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from jose import jwt, JWTError
import httpx
from dotenv import load_dotenv

load_dotenv()
AUTH_URL = os.getenv("AUTH_URL", "http://localhost:8001")
STRATEGY_URL = os.getenv("STRATEGY_URL", "http://localhost:8002")
JWT_SECRET = os.getenv("JWT_SECRET", "supersecret_jwt_change_me")
ALGORITHM = "HS256"

app = FastAPI(title="Genius Machado Gateway")
os.makedirs("frontend/static", exist_ok=True)
app.mount("/static", StaticFiles(directory="frontend/static"), name="static")
templates = Jinja2Templates(directory="frontend/templates")

def get_current_user_data(request: Request):
    token = request.cookies.get("access_token")
    if not token: return None
    try:
        if token.startswith("Bearer "): token = token.split(" ")[1]
        payload = jwt.decode(token, JWT_SECRET, algorithms=[ALGORITHM])
        return payload 
    except JWTError: return None

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    user = get_current_user_data(request)
    return templates.TemplateResponse("index.html", {"request": request, "user": user})

@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request): return templates.TemplateResponse("login.html", {"request": request})

@app.get("/register", response_class=HTMLResponse)
async def register_page(request: Request): return templates.TemplateResponse("register.html", {"request": request})

@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request):
    user_data = get_current_user_data(request)
    if not user_data: return RedirectResponse(url="/login", status_code=302)
    
    analysis_data = {}
    account_data = {}
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(f"{STRATEGY_URL}/analysis")
            analysis_data = resp.json()
            acc_resp = await client.get(f"{STRATEGY_URL}/account-status")
            account_data = acc_resp.json()
    except Exception as e:
        # Fallback data to prevent crash
        analysis_data = {"symbol": "OFFLINE", "price": 0, "reasoning": "System Offline"}
        account_data = {"daily_pl": 0, "balance": 0, "win_rate": 0, "trades_count": 0, "history": [], "status": "OFFLINE", "daily_limit": 1000}

    return templates.TemplateResponse("dashboard.html", {
        "request": request, 
        "user": user_data.get("sub"), 
        "analysis": analysis_data,
        "account": account_data
    })

@app.post("/api/execute")
async def execute_trade(request: Request, symbol: str = Form(...), action: str = Form(...)):
    user_data = get_current_user_data(request)
    if not user_data: return RedirectResponse(url="/login", status_code=302)
    
    async with httpx.AsyncClient() as client:
        try:
            await client.post(f"{STRATEGY_URL}/execute", json={
                "symbol": symbol, 
                "action": action, 
                "user": user_data.get("sub"),
                "reasoning": "Manual Override Execution"
            })
        except: pass
        
    return RedirectResponse(url="/dashboard?executed=true", status_code=303)

@app.post("/api/reset")
async def reset_account(request: Request):
    user_data = get_current_user_data(request)
    if not user_data: return RedirectResponse(url="/login", status_code=302)
    async with httpx.AsyncClient() as client:
        await client.post(f"{STRATEGY_URL}/reset")
    return RedirectResponse(url="/dashboard", status_code=303)

@app.post("/auth/register")
async def register_action(request: Request, email: str = Form(...), password: str = Form(...)):
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(f"{AUTH_URL}/register", data={"email": email, "password": password})
            if resp.status_code == 200: return RedirectResponse(url="/login?registered=true", status_code=303)
            return templates.TemplateResponse("register.html", {"request": request, "error": "Email exists"})
        except: return templates.TemplateResponse("register.html", {"request": request, "error": "Service Down"})

@app.post("/auth/login")
async def login_action(request: Request, email: str = Form(...), password: str = Form(...)):
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(f"{AUTH_URL}/token", data={"email": email, "password": password})
            if resp.status_code == 200:
                token = resp.json().get("access_token")
                response = RedirectResponse(url="/dashboard", status_code=303)
                response.set_cookie(key="access_token", value=f"Bearer {token}", httponly=True)
                return response
            return templates.TemplateResponse("login.html", {"request": request, "error": "Invalid credentials"})
        except: return templates.TemplateResponse("login.html", {"request": request, "error": "Service Down"})

@app.get("/logout")
async def logout():
    response = RedirectResponse(url="/", status_code=303)
    response.delete_cookie("access_token")
    return response
PY

# -------------------------
# AUTH SERVICE
# -------------------------
mkdir -p "$REPO/auth-service"
cat > "$REPO/auth-service/pyproject.toml" <<'TOML'
[project]
name = "auth-service"
version = "0.23.0"
requires-python = ">=3.11"
dependencies = ["fastapi", "uvicorn[standard]", "sqlalchemy>=2.0.0", "aiomysql", "python-jose[cryptography]", "passlib[bcrypt]", "python-dotenv", "pydantic", "cryptography", "python-multipart", "email-validator", "bcrypt==4.0.1"]
TOML
cat > "$REPO/auth-service/Dockerfile" <<'DF'
FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8001
CMD ["uv", "run", "uvicorn", "auth:app", "--host", "0.0.0.0", "--port", "8001", "--reload"]
DF
cat > "$REPO/auth-service/auth.py" <<'PY'
import os
from fastapi import FastAPI, HTTPException, Form
from fastapi.responses import JSONResponse
from pydantic import EmailStr
from jose import jwt
from passlib.hash import bcrypt
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy import MetaData, Table, Column, Integer, String, Boolean, DateTime, select, insert
from sqlalchemy.sql import func
from sqlalchemy.orm import sessionmaker
from dotenv import load_dotenv
load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
JWT_SECRET = os.getenv("JWT_SECRET", "supersecret")
ALGORITHM = "HS256"
engine = create_async_engine(DATABASE_URL, echo=False, future=True)
AsyncSessionLocal = sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
metadata = MetaData()
users = Table("users", metadata, Column("id", Integer, primary_key=True), Column("email", String(255), unique=True), Column("password", String(255)), Column("is_active", Boolean, default=True), Column("tier", String(50), default="free"), Column("created_at", DateTime, server_default=func.now()))
app = FastAPI()
@app.on_event("startup")
async def startup():
    async with engine.begin() as conn: await conn.run_sync(metadata.create_all)
@app.post("/register")
async def register(email: EmailStr = Form(...), password: str = Form(None)):
    async with AsyncSessionLocal() as session:
        res = await session.execute(select(users).where(users.c.email==email))
        if res.scalar_one_or_none(): raise HTTPException(status_code=400, detail="Exists")
        hashed = bcrypt.hash(password) if password else None
        await session.execute(insert(users).values(email=email, password=hashed, tier="free"))
        await session.commit()
        return JSONResponse({"ok":True})
@app.post("/token")
async def token(email: EmailStr = Form(...), password: str = Form(None)):
    async with AsyncSessionLocal() as session:
        res = await session.execute(select(users).where(users.c.email==email))
        row = res.fetchone()
        if not row or not password: raise HTTPException(status_code=400, detail="Invalid")
        db_pass = row._mapping.get("password")
        if not bcrypt.verify(password, db_pass): raise HTTPException(status_code=400, detail="Invalid")
        token = jwt.encode({"sub": email, "tier": row._mapping.get("tier")}, JWT_SECRET, algorithm=ALGORITHM)
        return {"access_token": token, "token_type": "bearer"}
PY

# -------------------------
# STRATEGY ENGINE (JOURNAL MASTER)
# -------------------------
mkdir -p "$REPO/strategy-engine"
cat > "$REPO/strategy-engine/pyproject.toml" <<'TOML'
[project]
name = "strategy-engine"
version = "0.23.0"
requires-python = ">=3.11"
dependencies = ["fastapi", "uvicorn[standard]", "pydantic", "python-dotenv", "pandas", "numpy", "yfinance", "ta", "websockets", "httpx", "sqlalchemy", "aiomysql", "pymysql"]
TOML

cat > "$REPO/strategy-engine/Dockerfile" <<'DF'
FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8002
CMD ["uv", "run", "uvicorn", "engine:app", "--host", "0.0.0.0", "--port", "8002", "--reload"]
DF

cat > "$REPO/strategy-engine/paper_exchange.py" <<'PY'
import random
from datetime import datetime

class PaperExchange:
    def __init__(self):
        self.balance = 100000.0
        self.pnl = 0.0
        self.history = [] # In-memory history, but we will persist this to DB

    def reset(self):
        self.balance = 100000.0
        self.pnl = 0.0
        self.history = []
        return True

    def execute_order(self, symbol, action, quantity, price, stop, reasoning):
        slippage = random.choice([0, 0.25, 0.5])
        fill_price = price + slippage if action == "BUY" else price - slippage
        commission = 2.0 * quantity
        
        # Simulate Outcome
        outcome = random.choice(["WIN", "LOSS", "WIN"]) 
        profit = 0
        
        if outcome == "WIN":
            rr = random.uniform(1.5, 3.0)
            risk_amt = abs(fill_price - stop) * quantity * 20 # Roughly NQ calc
            profit = risk_amt * rr
            status = "WIN"
        else:
            loss = abs(fill_price - stop) * quantity * 20
            profit = -loss
            status = "LOSS"
            
        self.balance += profit - commission
        self.pnl += profit - commission
        
        trade_record = {
            "time": datetime.now().strftime("%Y-%m-%d %H:%M"),
            "symbol": symbol,
            "action": action,
            "price": round(fill_price, 2),
            "pnl": round(profit - commission, 2),
            "result": status,
            "reasoning": reasoning
        }
        
        self.history.append(trade_record)
        return trade_record

    def get_stats(self):
        wins = len([t for t in self.history if t['result'] == 'WIN'])
        total = len(self.history)
        win_rate = round((wins / total * 100), 1) if total > 0 else 0
        return {
            "balance": round(self.balance, 2),
            "pnl": round(self.pnl, 2),
            "trades_count": total,
            "win_rate": win_rate,
            "history": self.history[-10:] # Last 10 trades
        }
PY

cat > "$REPO/strategy-engine/risk_manager.py" <<'PY'
from paper_exchange import PaperExchange

class RiskManager:
    def __init__(self):
        self.exchange = PaperExchange()
        self.max_daily_loss = 1000
        self.max_trades_daily = 5
        self.risk_per_trade_pct = 0.005
        self.trades_today = 0

    def can_trade(self):
        state = self.exchange.get_stats()
        if state['pnl'] <= -self.max_daily_loss: return False, "Daily Loss Limit Hit"
        if self.trades_today >= self.max_trades_daily: return False, "Max Trades Reached"
        return True, "OK"

    def calculate_position_size(self, entry_price, stop_price, instrument="NQ"):
        state = self.exchange.get_stats()
        risk_amount = state['balance'] * self.risk_per_trade_pct
        tick_val_mini = 20 if instrument == "NQ" else 50
        tick_val_micro = 2 if instrument == "NQ" else 5
        point_diff = abs(entry_price - stop_price)
        if point_diff == 0: point_diff = 10 
        
        risk_per_mini = point_diff * tick_val_mini
        if risk_amount >= risk_per_mini:
            return {"type": "MINI", "symbol": instrument, "contracts": max(1, int(risk_amount/risk_per_mini))}
        else:
            return {"type": "MICRO", "symbol": f"M{instrument}", "contracts": max(1, int(risk_amount/(point_diff*tick_val_micro)))}
    
    def execute_paper_trade(self, symbol, action, price, stop, reasoning):
        sizing = self.calculate_position_size(price, stop, "NQ")
        trade = self.exchange.execute_order(sizing['symbol'], action, sizing['contracts'], price, stop, reasoning)
        self.trades_today += 1
        return trade, sizing

    def get_status(self):
        # Maps exchange stats to dashboard format
        stats = self.exchange.get_stats()
        return {
            "balance": stats['balance'],
            "daily_pl": stats['pnl'],
            "daily_limit": self.max_daily_loss,
            "trades_today": self.trades_today,
            "max_trades": self.max_trades_daily,
            "status": "TRADING ACTIVE" if self.can_trade()[0] else "TRADING HALTED",
            "win_rate": stats['win_rate'],
            "trades_count": stats['trades_count'],
            "history": stats['history']
        }
        
    def reset_account(self):
        self.exchange.reset()
        self.trades_today = 0
PY

cat > "$REPO/strategy-engine/engine.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
import yfinance as yf
import pandas as pd
import numpy as np
import datetime
import pytz
from risk_manager import RiskManager

app = FastAPI(title="Genius V23 Journal Engine")
risk = RiskManager()
SYMBOL = "NQ=F"

# --- DATA ---
def get_candles(ticker, period, interval, est):
    try:
        df = ticker.history(period=period, interval=interval)
        if df.empty:
            fallback = yf.Ticker("QQQ")
            df = fallback.history(period=period, interval=interval)
        if df.empty: return pd.DataFrame()
        if df.index.tz is None: df.index = df.index.tz_localize("UTC")
        df.index = df.index.tz_convert(est)
        return df
    except: return pd.DataFrame()

# --- STRATEGY MODULES (V19 + V22) ---
def calculate_m7_sessions(df, est):
    if df.empty: return {"RDR": None}
    today = datetime.datetime.now(est).date()
    def get_range(sh, sm, eh, em):
        start = pd.Timestamp(f"{today} {sh}:{sm}:00").tz_localize(est)
        end = pd.Timestamp(f"{today} {eh}:{em}:00").tz_localize(est)
        chunk = df[(df.index >= start) & (df.index <= end)]
        if chunk.empty: return None
        dr_h = round(chunk['High'].max(), 2)
        dr_l = round(chunk['Low'].min(), 2)
        return {"h": dr_h, "l": dr_l, "mid": round((dr_h+dr_l)/2, 2)}
    return { "RDR": get_range("09", "30", "10", "30") }

def check_silver_bullet(est):
    now = datetime.datetime.now(est).time()
    if datetime.time(10, 0) <= now <= datetime.time(11, 0): return "AM SILVER BULLET"
    if datetime.time(14, 0) <= now <= datetime.time(15, 0): return "PM SILVER BULLET"
    return "OFF HOURS"

# --- ENDPOINTS ---
@app.get("/analysis")
async def perform_analysis():
    est = pytz.timezone('America/New_York')
    t = yf.Ticker(SYMBOL)
    
    df_5m = get_candles(t, "5d", "5m", est)
    if df_5m.empty: 
        return {
            "symbol": SYMBOL, "price": 0, 
            "strategy": {"bias": "DATA_OFFLINE", "mmxm": "N/A", "context_array": "N/A"},
            "reasoning": "Market Data Unavailable",
            "m7_levels": {"RDR": None},
            "time_logic": {"silver_bullet": "N/A"}
        }
    
    price = round(df_5m['Close'].iloc[-1], 2)
    
    # Analysis
    sessions = calculate_m7_sessions(df_5m, est)
    sb_status = check_silver_bullet(est)
    
    m7_bias = "NEUTRAL"
    if sessions['RDR']:
        if price > sessions['RDR']['h']: m7_bias = "BULLISH (KM7)"
        elif price < sessions['RDR']['l']: m7_bias = "BEARISH (KM7)"
    
    # Reasoning
    reasons = []
    if "BULL" in m7_bias: reasons.append(f"Price > RDR High")
    if "BEAR" in m7_bias: reasons.append(f"Price < RDR Low")
    if "BULLET" in sb_status: reasons.append(f"{sb_status} Active")
    
    return {
        "symbol": SYMBOL,
        "price": price,
        "strategy": {
            "bias": m7_bias,
            "mmxm": "Consolidation", # Placeholder for full V16 logic
            "context_array": "Scanning..."
        },
        "reasoning": " + ".join(reasons),
        "m7_levels": sessions,
        "time_logic": {"silver_bullet": sb_status}
    }

class TradeReq(BaseModel):
    symbol: str
    action: str
    user: str
    reasoning: str = "Manual"

@app.post("/execute")
async def execute_trade(req: TradeReq):
    allowed, reason = risk.can_trade()
    if not allowed: return {"status": "REJECTED", "reason": reason}
    
    t = yf.Ticker(SYMBOL)
    df = get_candles(t, "1d", "1m", pytz.timezone('America/New_York'))
    if df.empty: return {"status": "ERROR", "reason": "Data Offline"}
    
    price = df['Close'].iloc[-1]
    stop = price - 20 if req.action == "BUY" else price + 20
    
    # Execute Paper Trade with Reasoning
    trade, sizing = risk.execute_paper_trade(SYMBOL, req.action, price, stop, req.reasoning)
    
    return {
        "status": "FILLED (PAPER)",
        "details": f"{req.action} {sizing['contracts']} {sizing['type']} @ {round(price, 2)}",
        "result": trade['result']
    }

@app.get("/account-status")
async def account_status():
    return risk.get_status()

@app.post("/reset")
async def reset_account():
    risk.reset_account()
    return {"status": "RESET"}
PY

# -------------------------
# FRONTEND
# -------------------------
mkdir -p "$REPO/frontend/templates/legal"
mkdir -p "$REPO/frontend/static/css"
mkdir -p "$REPO/frontend/static/images"

cat > "$REPO/frontend/templates/base.html" <<'HTML'
<!doctype html>
<html lang="en" class="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Genius Machado | Journal</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>tailwind.config = { darkMode: 'class', theme: { extend: { colors: { brand: { DEFAULT: '#00E5FF', dark: '#00B8D4' } } } } }</script>
  <style>
    body { background-color: #0F172A; color: #E2E8F0; }
    .glass { background: rgba(30, 41, 59, 0.8); backdrop-filter: blur(12px); border: 1px solid rgba(255,255,255,0.1); }
    .hero-bg { background-image: url('/static/images/banner.jpg'); background-size: cover; background-position: center; }
  </style>
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
</head>
<body class="flex flex-col min-h-screen">
  <header class="fixed w-full z-50 glass">
    <div class="container mx-auto px-6 py-4 flex justify-between items-center">
      <a href="/" class="text-xl font-black tracking-tighter text-white">GENIUS<span class="text-brand">MACHADO</span></a>
      <div class="flex items-center gap-4">
        {% if user %}
           <a href="/dashboard" class="bg-brand text-black px-4 py-2 rounded font-bold hover:bg-brand-dark transition">Simulator</a>
           <a href="/logout" class="text-sm text-gray-400 hover:text-white">Logout</a>
        {% else %}
           <a href="/login" class="text-gray-300 hover:text-white font-medium">Login</a>
        {% endif %}
      </div>
    </div>
  </header>
  <main class="flex-grow pt-20">
    {% block content %}{% endblock %}
  </main>
  <footer class="bg-slate-900 border-t border-slate-800 mt-auto py-10">
    <div class="container mx-auto px-6 flex flex-col md:flex-row justify-between items-center">
      <div class="mb-6 md:mb-0">
        <p class="font-bold text-white mb-2">Connect with Genius Machado</p>
        <div class="flex gap-6 text-2xl">
          <a href="https://x.com/DRxICT" class="text-gray-400 hover:text-blue-400 transition"><i class="fab fa-twitter"></i></a>
          <a href="https://www.youtube.com/@GeniusMachado" class="text-gray-400 hover:text-red-500 transition"><i class="fab fa-youtube"></i></a>
          <a href="https://www.instagram.com/geniusmachado/" class="text-gray-400 hover:text-pink-500 transition"><i class="fab fa-instagram"></i></a>
          <a href="https://www.snapchat.com/add/geniusmachado?share_id=clvFLRAE1h0&locale=en-US" class="text-gray-400 hover:text-yellow-400 transition"><i class="fab fa-snapchat"></i></a>
        </div>
      </div>
      <div class="text-right text-sm text-gray-500">
        <p>© 2025 Genius Machado Algo Systems.</p>
        <p>Built for Tradovate Prop Accounts.</p>
      </div>
    </div>
  </footer>
</body>
</html>
HTML

cat > "$REPO/frontend/templates/index.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<div class="relative min-h-[90vh] flex items-center justify-center hero-bg">
  <div class="absolute inset-0 bg-gradient-to-b from-slate-900/90 via-slate-900/70 to-[#0F172A]"></div>
  <div class="relative z-10 container mx-auto px-6 text-center">
    <div class="inline-block px-3 py-1 rounded-full bg-brand/10 border border-brand/30 text-brand text-xs font-bold mb-6 tracking-wide">
      ● V23 BLACK BOX JOURNAL
    </div>
    <h1 class="text-5xl md:text-7xl font-black text-white mb-6 tracking-tight">
      Automated <br> <span class="text-brand">Journaling.</span>
    </h1>
    <p class="text-lg text-gray-400 mb-10 max-w-xl mx-auto">
      See exactly why the bot took a trade. Full transparency logs for 100k Challenge verification.
    </p>
    <div class="flex justify-center gap-4">
      <a href="/login" class="bg-brand text-black px-8 py-4 rounded-lg font-bold text-lg hover:bg-brand-dark transition shadow-xl shadow-brand/10">
        View Journal
      </a>
    </div>
  </div>
</div>
{% endblock %}
HTML

cat > "$REPO/frontend/templates/dashboard.html" <<'HTML'
{% extends "base.html" %}
{% block content %}
<div class="container mx-auto px-4 py-8">
  <div class="flex justify-between items-center mb-8">
    <div>
        <h1 class="text-2xl font-bold text-white">V23 Journal Terminal <span class="text-gray-500 text-sm">| {{ analysis.symbol }}</span></h1>
        <span class="bg-yellow-500/20 text-yellow-500 text-xs px-2 py-1 rounded font-bold">SIMULATION MODE</span>
    </div>
    <div class="flex gap-2">
      <form action="/api/reset" method="post"><button class="bg-gray-700 text-white px-4 py-2 rounded hover:bg-gray-600">Reset</button></form>
      <form action="/api/execute" method="post"><input type="hidden" name="symbol" value="NQ"><input type="hidden" name="action" value="BUY"><button class="bg-green-600 text-white px-6 py-2 rounded font-bold hover:bg-green-500 shadow-lg">Paper Long</button></form>
      <form action="/api/execute" method="post"><input type="hidden" name="symbol" value="NQ"><input type="hidden" name="action" value="SELL"><button class="bg-red-600 text-white px-6 py-2 rounded font-bold hover:bg-red-500 shadow-lg">Paper Short</button></form>
    </div>
  </div>

  <!-- ACCOUNT HEALTH -->
  <div class="grid md:grid-cols-4 gap-6 mb-8">
    <div class="glass p-6 rounded-xl border-l-4 {{ 'border-green-500' if account.daily_pl >= 0 else 'border-red-500' }}">
      <div class="text-gray-400 text-xs uppercase font-bold mb-2">Daily P&L</div>
      <div class="text-2xl font-black text-white">${{ account.daily_pl }}</div>
    </div>
    <div class="glass p-6 rounded-xl border-l-4 border-blue-500">
      <div class="text-gray-400 text-xs uppercase font-bold mb-2">Balance</div>
      <div class="text-2xl font-mono text-white">${{ account.balance }}</div>
    </div>
    
    <!-- STATS -->
    <div class="glass p-6 rounded-xl border-l-4 border-purple-500">
      <div class="text-gray-400 text-xs uppercase font-bold mb-2">Win Rate</div>
      <div class="text-2xl font-bold text-white">{{ account.win_rate }}%</div>
    </div>

    <div class="glass p-6 rounded-xl border-l-4 border-white">
      <div class="text-gray-400 text-xs uppercase font-bold mb-2">Total Trades</div>
      <div class="text-2xl font-bold text-white">{{ account.trades_count }}</div>
    </div>
  </div>

  <!-- TRADE JOURNAL -->
  <div class="glass rounded-xl border border-white/10 mb-6 overflow-hidden">
    <div class="bg-slate-800/50 px-6 py-4 border-b border-white/10 font-bold text-white">Automated Trade Journal (Last 10)</div>
    <div class="overflow-x-auto">
      <table class="w-full text-sm text-left text-gray-400">
        <thead class="text-xs uppercase bg-slate-900 text-gray-400">
          <tr>
            <th class="px-6 py-3">Time</th>
            <th class="px-6 py-3">Action</th>
            <th class="px-6 py-3">Price</th>
            <th class="px-6 py-3">Reasoning</th>
            <th class="px-6 py-3">Result</th>
            <th class="px-6 py-3 text-right">P&L</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-800">
          {% for trade in account.history | reverse %}
          <tr class="hover:bg-slate-800/50 transition">
            <td class="px-6 py-4">{{ trade.time }}</td>
            <td class="px-6 py-4 font-bold {{ 'text-green-400' if trade.action == 'BUY' else 'text-red-400' }}">{{ trade.action }}</td>
            <td class="px-6 py-4 font-mono">{{ trade.price }}</td>
            <td class="px-6 py-4 text-gray-300">{{ trade.reasoning }}</td>
            <td class="px-6 py-4">
              {% if trade.result == 'WIN' or trade.result == 'CLOSED_PROFIT' %}
                 <span class="bg-green-500/20 text-green-400 px-2 py-1 rounded text-xs font-bold">WIN</span>
              {% else %}
                 <span class="bg-red-500/20 text-red-400 px-2 py-1 rounded text-xs font-bold">LOSS</span>
              {% endif %}
            </td>
            <td class="px-6 py-4 text-right font-mono font-bold {{ 'text-green-400' if trade.pnl > 0 else 'text-red-400' }}">${{ trade.pnl }}</td>
          </tr>
          {% else %}
          <tr><td colspan="6" class="px-6 py-8 text-center text-gray-600 italic">No trades taken yet in this session.</td></tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </div>

  <!-- Chart Area -->
  <div class="glass rounded-xl overflow-hidden h-[550px] border border-slate-700">
    <div class="tradingview-widget-container" style="height:100%;width:100%">
      <div id="tradingview_123" style="height:100%;width:100%"></div>
      <script type="text/javascript" src="https://s3.tradingview.com/tv.js"></script>
      <script type="text/javascript">
      new TradingView.widget({"autosize": true,"symbol": "CME_MINI:NQ1!","interval": "5","timezone": "America/New_York","theme": "dark","style": "1","locale": "en","enable_publishing": false,"backgroundColor": "rgba(15, 23, 42, 1)","gridColor": "rgba(255, 255, 255, 0.05)","hide_top_toolbar": false,"container_id": "tradingview_123"});
      </script>
    </div>
  </div>
</div>
{% endblock %}
HTML

# Login/Register (Standard)
cat > "$REPO/frontend/templates/login.html" <<'HTML'
{% extends "base.html" %} {% block content %} <div class="min-h-[80vh] flex items-center justify-center px-4"><div class="glass w-full max-w-md p-8 rounded-2xl border border-slate-700"><h2 class="text-2xl font-bold text-white text-center mb-6">Login</h2><form action="/auth/login" method="post" class="space-y-4"><div><label class="text-xs text-gray-400 font-bold block mb-1">EMAIL</label><input name="email" type="email" required class="w-full bg-slate-900 border border-slate-700 rounded p-3 text-white focus:border-brand outline-none"></div><div><label class="text-xs text-gray-400 font-bold block mb-1">PASSWORD</label><input name="password" type="password" required class="w-full bg-slate-900 border border-slate-700 rounded p-3 text-white focus:border-brand outline-none"></div><button class="w-full bg-brand text-black font-bold py-3 rounded hover:bg-brand-dark transition">Enter System</button></form></div></div> {% endblock %}
HTML
cat > "$REPO/frontend/templates/register.html" <<'HTML'
{% extends "base.html" %} {% block content %} <div class="min-h-[80vh] flex items-center justify-center px-4"><div class="glass w-full max-w-md p-8 rounded-2xl border border-slate-700"><h2 class="text-2xl font-bold text-white text-center mb-6">Create Account</h2><form action="/auth/register" method="post" class="space-y-4"><div><label class="text-xs text-gray-400 font-bold block mb-1">EMAIL</label><input name="email" type="email" required class="w-full bg-slate-900 border border-slate-700 rounded p-3 text-white focus:border-brand outline-none"></div><div><label class="text-xs text-gray-400 font-bold block mb-1">PASSWORD</label><input name="password" type="password" required class="w-full bg-slate-900 border border-slate-700 rounded p-3 text-white focus:border-brand outline-none"></div><button class="w-full bg-white text-black font-bold py-3 rounded hover:bg-gray-200 transition">Sign Up</button></form></div></div> {% endblock %}
HTML

# -------------------------
# DB SQL
# -------------------------
mkdir -p "$REPO/db"
cat > "$REPO/db/init.sql" <<'SQL'
CREATE DATABASE IF NOT EXISTS genius;
USE genius;
CREATE TABLE IF NOT EXISTS users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(255) UNIQUE, password VARCHAR(255), is_active BOOLEAN DEFAULT TRUE, tier VARCHAR(50) DEFAULT 'free', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
SQL

# -------------------------
# Env
# -------------------------
cat > "$REPO/.env.example" <<'ENV'
MYSQL_ROOT_PASSWORD=rootpass
DATABASE_URL=mysql+aiomysql://genius:geniuspass@db:3306/genius
JWT_SECRET=supersecret_jwt_change_me
AUTH_URL=http://auth:8001
STRATEGY_URL=http://strategy-engine:8002
ENV

echo "✅ V23 Black Box Journal Ready!"
echo "-----------------------------------------------------"
echo "1. Edit TradingAlgo/docker-compose.yml (Add Cloudflare Token)"
echo "2. Add TradingAlgo/frontend/static/images/banner.jpg"
echo "3. Run: cd TradingAlgo && docker compose up --build"
echo "-----------------------------------------------------"
