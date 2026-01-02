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
