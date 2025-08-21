//+------------------------------------------------------------------+
//|                                                EMA_ATR_Trend.mq5 |
//|                           Trend-Following EMA + ATR EA (MQL5)   |
//|   Entries with EMA trend; ATR-based SL/TP; ATR trailing stop;    |
//|   risk-based position sizing.                                    |
//+------------------------------------------------------------------+
#property copyright   "Public Domain"
#property version     "1.01"
#property description "EMA trend-following with ATR risk mgmt"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//--- Inputs
input int      InpEMAPeriod         = 200;      // EMA period
input int      InpATRPeriod         = 14;       // ATR period
input double   InpSL_ATR_Mult       = 1.5;      // Stop-Loss = ATR * this
input double   InpTP_RR             = 2.0;      // Take-Profit Risk/Reward multiple (TP = SL * RR)
input double   InpTrail_ATR_Mult    = 1.5;      // Trailing SL = ATR * this
input bool     InpUseTrailing       = true;     // Use ATR trailing stop
input double   InpRiskPercent       = 1.0;      // % of equity risked per trade
input bool     InpAllowLong         = true;     // Allow long trades
input bool     InpAllowShort        = true;     // Allow short trades
input int      InpSlippagePoints    = 5;        // Max slippage (points)
input long     InpMagic             = 20250821; // Magic number

//--- Global handles
int ema_handle = INVALID_HANDLE;
int atr_handle = INVALID_HANDLE;

//--- Utility: fetch latest and previous values from an indicator buffer
bool GetLatest(int handle, double &prev, double &curr)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(handle, 0, 0, 2, buf);
   if(copied < 2) return false;
   curr = buf[0]; // current bar
   prev = buf[1]; // previous bar
   return true;
}

//--- Utility: position helpers
bool HasOpenPosition(ENUM_POSITION_TYPE type, ulong &ticket, double &sl, double &tp)
{
   if(PositionSelect(_Symbol))
   {
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == ptype)
      {
         ticket = (ulong)PositionGetInteger(POSITION_TICKET);
         sl = PositionGetDouble(POSITION_SL);
         tp = PositionGetDouble(POSITION_TP);
         return true;
      }
   }
   return false;
}

bool HasAnyPosition()
{
   return PositionSelect(_Symbol);
}

//--- Money & volume calculations
// Value of one point per 1.0 lot in deposit currency
double PointValuePerLot()
{
   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tick_sz <= 0.0) return 0.0;
   return tick_val * (point / tick_sz);
}

// Round volume to broker's step and limits
double NormalizeVolume(double lots)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Clamp to broker limits
   lots = MathMax(minv, MathMin(maxv, lots));

   if(step > 0.0)
   {
      lots = MathRound(lots / step) * step; // snap to step
      int vol_digits = (int)MathMax(0.0, MathCeil(-MathLog10(step))); // derive decimals from step
      lots = NormalizeDouble(lots, vol_digits);
   }
   return lots;
}

// Compute position size for a given stop distance in PRICE (not points)
// Risk = InpRiskPercent% of equity
double ComputeLots(double stop_distance_price)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * InpRiskPercent / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stop_points = stop_distance_price / point;
   double value_per_point_per_lot = PointValuePerLot();
   if(value_per_point_per_lot <= 0 || stop_points <= 0) return 0.0;
   double lots = risk_money / (value_per_point_per_lot * stop_points);
   return NormalizeVolume(lots);
}

//--- Initialize
int OnInit()
{
   ema_handle = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(ema_handle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle: ", GetLastError());
      return INIT_FAILED;
   }
   atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle: ", GetLastError());
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
}

//--- Core logic
void OnTick()
{
   if(Bars(_Symbol, PERIOD_CURRENT) < MathMax(InpEMAPeriod, InpATRPeriod) + 5)
      return;

   double ema_prev, ema_curr;   if(!GetLatest(ema_handle, ema_prev, ema_curr)) return;
   double atr_prev, atr_curr;   if(!GetLatest(atr_handle, atr_prev, atr_curr)) return;

   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   double bid = tick.bid; double ask = tick.ask; double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Manage existing position (trailing)
   if(PositionSelect(_Symbol))
   {
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur_sl     = PositionGetDouble(POSITION_SL);
      ulong  ticket     = (ulong)PositionGetInteger(POSITION_TICKET);

      if(InpUseTrailing)
      {
         if(ptype == POSITION_TYPE_BUY)
         {
            double new_sl = bid - InpTrail_ATR_Mult * atr_curr;
            if(cur_sl <= 0 || new_sl - cur_sl > 3*point)
            {
               new_sl = MathMax(cur_sl, MathMin(new_sl, bid - 3*point));
               trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
            }
         }
         else if(ptype == POSITION_TYPE_SELL)
         {
            double new_sl = ask + InpTrail_ATR_Mult * atr_curr;
            if(cur_sl <= 0 || cur_sl - new_sl > 3*point)
            {
               new_sl = MathMin(cur_sl, MathMax(new_sl, ask + 3*point));
               trade.PositionModify(ticket, new_sl, PositionGetDouble(POSITION_TP));
            }
         }
      }
      return; // only one position per symbol
   }

   // No open position: look for signals (cross of price vs EMA)
   double close_buf[2];
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 2, close_buf) != 2) return;
   double curr_close = close_buf[0];
   double prev_close = close_buf[1];

   // Long entry: cross up
   bool cross_up   = (prev_close <= ema_prev) && (curr_close > ema_curr);
   // Short entry: cross down
   bool cross_down = (prev_close >= ema_prev) && (curr_close < ema_curr);

   // Prepare order parameters with ATR-based SL/TP
   double sl_dist = InpSL_ATR_Mult * atr_curr; // in PRICE units
   if(sl_dist <= 0) return;
   double lots = ComputeLots(sl_dist);
   if(lots <= 0) return;

   if(InpAllowLong && cross_up)
   {
      double sl = curr_close - sl_dist;
      double tp = curr_close + sl_dist * InpTP_RR;
      trade.SetDeviationInPoints(InpSlippagePoints);
      trade.Buy(lots, _Symbol, ask, sl, tp, "EMA_ATR_Long");
   }
   else if(InpAllowShort && cross_down)
   {
      double sl = curr_close + sl_dist;
      double tp = curr_close - sl_dist * InpTP_RR;
      trade.SetDeviationInPoints(InpSlippagePoints);
      trade.Sell(lots, _Symbol, bid, sl, tp, "EMA_ATR_Short");
   }
}

//+------------------------------------------------------------------+
//| Notes                                                             |
//| - Attach to chart/timeframe of choice.                            |
//| - Backtest to see ATR-based SL/TP & trailing behavior.            |
//| - Only one position per symbol is managed to keep it simple.      |
//| - Risk-based sizing adapts to volatility via ATR-derived stop.    |
//+------------------------------------------------------------------+
