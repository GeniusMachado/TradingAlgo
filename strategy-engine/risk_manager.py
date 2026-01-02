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
