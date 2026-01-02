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
