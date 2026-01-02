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
