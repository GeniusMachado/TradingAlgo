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
