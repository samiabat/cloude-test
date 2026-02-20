//+------------------------------------------------------------------+
//| ICT_SilverBullet_EA.mq5                                         |
//| ICT Silver Bullet Expert Advisor for MetaTrader 5                |
//| Optimized for NQ (Nasdaq) and XAU (Gold)                         |
//|                                                                  |
//| Core Logic:                                                      |
//|   1. Trade only during NY AM Silver Bullet: 10:00-11:00 EST.    |
//|   2. Detect Liquidity Sweeps of recent swing highs/lows.        |
//|   3. Confirm Market Structure Shift (MSS) with displacement.    |
//|   4. Identify Fair Value Gaps (FVG) on the displacement leg.    |
//|   5. Enter when price retraces into the FVG.                    |
//|   6. SL beyond FVG / displacement extreme, TP at 1:2 RR.       |
//|   7. 2% daily loss guardrail — halts trading for the day.       |
//|   8. Time exit at 11:15 AM EST.                                 |
//+------------------------------------------------------------------+
#property copyright   "ICT Silver Bullet EA"
#property link        ""
#property version     "1.00"
#property strict
#property description "ICT Silver Bullet strategy – NY AM session only"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input int      InpESTOffset      = -5;     // EST UTC offset (-5 winter, -4 summer)
input int      InpSessionStart   = 10;     // Session start hour (EST)
input int      InpSessionEnd     = 11;     // Session end hour (EST)
input int      InpTimeExitMin    = 15;     // Minutes past session end for time exit
input int      InpSwingLen       = 5;      // Swing detection lookback bars
input double   InpRRRatio        = 2.0;    // Risk:Reward ratio
input double   InpMaxDailyLoss   = 2.0;    // Max daily loss (% of balance)
input double   InpSLBufferPts    = 5.0;    // SL buffer in points beyond FVG
input double   InpRiskPercent    = 2.0;    // Risk per trade (% of balance)
input int      InpMagicNumber    = 20240101; // Magic number for order identification

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         trade;                // MQL5 trade helper

// ── Swing levels ──
double         g_lastSwingHigh;      // Most recent confirmed swing high
double         g_lastSwingLow;       // Most recent confirmed swing low
bool           g_swingHighValid;
bool           g_swingLowValid;

// ── Liquidity sweep flags (persist for one bar after the sweep) ──
bool           g_buySideSweep;       // Buy-side liquidity swept (swing high taken)
bool           g_sellSideSweep;      // Sell-side liquidity swept (swing low taken)
bool           g_prevBuySideSweep;   // Previous bar's buy-side sweep (for MSS sequencing)
bool           g_prevSellSideSweep;  // Previous bar's sell-side sweep (for MSS sequencing)

// ── Pending FVG zones ──
bool           g_pendingLong;
double         g_longFVG_top;        // Upper boundary of bullish FVG
double         g_longFVG_bottom;     // Lower boundary of bullish FVG
double         g_longSLRef;          // Displacement candle low (for SL)

bool           g_pendingShort;
double         g_shortFVG_top;       // Upper boundary of bearish FVG
double         g_shortFVG_bottom;    // Lower boundary of bearish FVG
double         g_shortSLRef;         // Displacement candle high (for SL)

// ── Daily loss tracking ──
double         g_dayStartBalance;    // Balance at the start of the trading day
int            g_lastDay;            // Calendar day of last reset
bool           g_dailyLossHit;       // True when daily loss cap is breached

// ── Bar tracking ──
datetime       g_lastBarTime;        // Prevents processing the same bar twice

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Configure the trade helper.
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize state.
   g_lastSwingHigh   = 0;
   g_lastSwingLow    = 0;
   g_swingHighValid  = false;
   g_swingLowValid   = false;

   g_buySideSweep      = false;
   g_sellSideSweep     = false;
   g_prevBuySideSweep  = false;
   g_prevSellSideSweep = false;

   g_pendingLong     = false;
   g_pendingShort    = false;

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastDay         = -1;
   g_dailyLossHit   = false;
   g_lastBarTime     = 0;

   Print("ICT Silver Bullet EA initialized. Magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("ICT Silver Bullet EA removed. Reason=", reason);
}

//+------------------------------------------------------------------+
//| TIMEZONE HELPERS                                                  |
//+------------------------------------------------------------------+

//--- Convert GMT time to EST hour.
//    Uses TimeGMT() for accurate UTC reference, avoiding broker server timezone ambiguity.
int GetESTHour()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = (dt.hour + InpESTOffset + 24) % 24;
   return h;
}

//--- Convert GMT time to EST minute.
int GetESTMinute()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return dt.min;
}

//--- True while inside the 10:00–11:00 EST setup window.
bool IsInSession()
{
   int h = GetESTHour();
   return (h >= InpSessionStart && h < InpSessionEnd);
}

//--- True at or past 11:15 EST (time exit).
bool IsPastTimeExit()
{
   int h = GetESTHour();
   int m = GetESTMinute();
   return (h > InpSessionEnd) || (h == InpSessionEnd && m >= InpTimeExitMin);
}

//+------------------------------------------------------------------+
//| DAILY LOSS GUARDRAIL                                             |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   // Convert GMT to EST time for accurate trading-day boundary detection.
   datetime estTime = TimeGMT() + InpESTOffset * 3600;
   MqlDateTime estDt;
   TimeToStruct(estTime, estDt);

   // Reset at the start of a new EST calendar day.
   if(estDt.day_of_year != g_lastDay)
   {
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLossHit    = false;
      g_lastDay         = estDt.day_of_year;
      Print("New day – daily P&L reset. Start balance=", g_dayStartBalance);
   }
}

bool IsDailyLossHit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   // Use the worse of balance and equity for a conservative check.
   double effectiveValue = MathMin(currentBalance, currentEquity);
   double loss           = g_dayStartBalance - effectiveValue;
   double maxLoss        = g_dayStartBalance * InpMaxDailyLoss / 100.0;
   return (loss >= maxLoss);
}

//+------------------------------------------------------------------+
//| POSITION HELPERS                                                  |
//+------------------------------------------------------------------+

//--- Count open positions for this EA (by magic number).
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL)  == _Symbol)
         count++;
   }
   return count;
}

//--- Close all positions for this EA.
void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL)  == _Symbol)
      {
         trade.PositionClose(ticket);
         Print("Closed position #", ticket, " – ", reason);
      }
   }
}

//+------------------------------------------------------------------+
//| LOT-SIZE CALCULATOR (Risk-based)                                 |
//+------------------------------------------------------------------+
double CalcLotSize(double riskPoints)
{
   if(riskPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = riskMoney / (riskPoints / tickSize * tickValue);

   // Clamp to broker limits.
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / lotStep) * lotStep;  // round down to step

   return lots;
}

//+------------------------------------------------------------------+
//| SWING HIGH / LOW DETECTION                                       |
//+------------------------------------------------------------------+
//  A swing high is a bar whose high is the highest of the surrounding
//  (InpSwingLen) bars on each side.  We look at the bar that is
//  InpSwingLen bars ago so that both sides are confirmed.
//+------------------------------------------------------------------+
void DetectSwings()
{
   int barsNeeded = InpSwingLen * 2 + 1;
   if(Bars(_Symbol, PERIOD_CURRENT) < barsNeeded + 2) return;

   // Copy highs and lows into buffers.
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);
   int copiedHighs = CopyHigh(_Symbol, PERIOD_CURRENT, 0, barsNeeded + 2, highs);
   int copiedLows  = CopyLow (_Symbol, PERIOD_CURRENT, 0, barsNeeded + 2, lows);

   if(copiedHighs < barsNeeded + 2 || copiedLows < barsNeeded + 2)
   {
      Print("DetectSwings: Insufficient data copied - highs=", copiedHighs, " lows=", copiedLows);
      return;
   }

   // The candidate bar is at index InpSwingLen (confirmed on both sides).
   int idx = InpSwingLen;
   bool isSwingHigh = true;
   bool isSwingLow  = true;

   for(int j = 1; j <= InpSwingLen; j++)
   {
      if(highs[idx] < highs[idx - j] || highs[idx] < highs[idx + j])
         isSwingHigh = false;
      if(lows[idx] > lows[idx - j] || lows[idx] > lows[idx + j])
         isSwingLow = false;
   }

   if(isSwingHigh)
   {
      g_lastSwingHigh  = highs[idx];
      g_swingHighValid = true;
   }
   if(isSwingLow)
   {
      g_lastSwingLow  = lows[idx];
      g_swingLowValid = true;
   }
}

//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP DETECTION                                        |
//+------------------------------------------------------------------+
//  Buy-side sweep: bar wicks above the last swing high but closes    |
//                  back below it.                                    |
//  Sell-side sweep: bar wicks below the last swing low but closes    |
//                  back above it.                                    |
//+------------------------------------------------------------------+
void DetectLiquiditySweeps(double barHigh, double barLow, double barClose)
{
   // Preserve previous bar's sweep state for MSS sequencing.
   g_prevBuySideSweep  = g_buySideSweep;
   g_prevSellSideSweep = g_sellSideSweep;

   g_buySideSweep  = false;
   g_sellSideSweep = false;

   if(g_swingHighValid && barHigh > g_lastSwingHigh && barClose < g_lastSwingHigh)
      g_buySideSweep = true;

   if(g_swingLowValid && barLow < g_lastSwingLow && barClose > g_lastSwingLow)
      g_sellSideSweep = true;
}

//+------------------------------------------------------------------+
//| MARKET STRUCTURE SHIFT (MSS) + FVG + ENTRY LOGIC                 |
//+------------------------------------------------------------------+
void ProcessStrategy()
{
   bool inSession      = IsInSession();
   bool pastExit       = IsPastTimeExit();

   // ── Time Exit ──
   if(pastExit && CountPositions() > 0)
   {
      CloseAllPositions("Time Exit 11:15 EST");
      g_pendingLong  = false;
      g_pendingShort = false;
   }

   // Reset pending zones when the session is over.
   if(pastExit)
   {
      g_pendingLong  = false;
      g_pendingShort = false;
   }

   // ── Daily Loss Halt ──
   if(g_dailyLossHit)
   {
      if(CountPositions() > 0)
         CloseAllPositions("Daily Loss Limit");
      return;  // No further processing today.
   }

   if(!inSession) return;  // Outside the window — nothing to do.

   // ── Fetch recent OHLC data ──
   double highs[], lows[], opens[], closes[];
   ArraySetAsSeries(highs,  true);
   ArraySetAsSeries(lows,   true);
   ArraySetAsSeries(opens,  true);
   ArraySetAsSeries(closes, true);
   if(CopyHigh (_Symbol, PERIOD_CURRENT, 0, 4, highs)  < 4) return;
   if(CopyLow  (_Symbol, PERIOD_CURRENT, 0, 4, lows)   < 4) return;
   if(CopyOpen (_Symbol, PERIOD_CURRENT, 0, 4, opens)  < 4) return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 4, closes) < 4) return;

   // Bar indices: 0 = current (forming), 1 = last closed, 2 = two bars ago, 3 = three bars ago.
   double barHigh  = highs[1];
   double barLow   = lows[1];
   double barOpen  = opens[1];
   double barClose = closes[1];

   // ── 1. Update swings ──
   DetectSwings();

   // ── 2. Detect liquidity sweeps on the last closed bar ──
   DetectLiquiditySweeps(barHigh, barLow, barClose);

   // ── 3. ATR for displacement check ──
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   if(atrHandle == INVALID_HANDLE) return;
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) < 1)
   {
      IndicatorRelease(atrHandle);
      return;
   }
   double atrVal = atrBuf[0];
   IndicatorRelease(atrHandle);

   double bodySize       = MathAbs(barClose - barOpen);
   bool   isDisplacement = bodySize > atrVal * 0.5;

   // ── 4. Bullish MSS: sell-side sweep on prior bar, current bar closes above prior high with displacement ──
   bool bullishMSS = false;
   if(g_prevSellSideSweep && barClose > highs[2] && isDisplacement && barClose > barOpen)
      bullishMSS = true;

   // ── 5. Bearish MSS: buy-side sweep on prior bar, current bar closes below prior low with displacement ──
   bool bearishMSS = false;
   if(g_prevBuySideSweep && barClose < lows[2] && isDisplacement && barClose < barOpen)
      bearishMSS = true;

   // ── 6. Fair Value Gap detection (3-candle pattern) ──
   // Bullish FVG: gap between bar[3].high and bar[1].low (bar[2] is the displacement candle).
   double bullFVG_top    = lows[1];
   double bullFVG_bottom = highs[3];
   bool   hasBullFVG     = bullFVG_top > bullFVG_bottom;

   // Bearish FVG: gap between bar[1].high and bar[3].low.
   double bearFVG_top    = lows[3];
   double bearFVG_bottom = highs[1];
   bool   hasBearFVG     = bearFVG_top > bearFVG_bottom;

   // ── 7. Latch pending FVG zones ──
   if(bullishMSS && hasBullFVG)
   {
      g_pendingLong    = true;
      g_longFVG_top    = bullFVG_top;
      g_longFVG_bottom = bullFVG_bottom;
      g_longSLRef      = lows[2];  // displacement candle low
      Print("Bullish FVG latched: top=", g_longFVG_top, " bottom=", g_longFVG_bottom);
   }

   if(bearishMSS && hasBearFVG)
   {
      g_pendingShort    = true;
      g_shortFVG_top    = bearFVG_top;
      g_shortFVG_bottom = bearFVG_bottom;
      g_shortSLRef      = highs[2]; // displacement candle high
      Print("Bearish FVG latched: top=", g_shortFVG_top, " bottom=", g_shortFVG_bottom);
   }

   // ── 8. Entry on retracement into the FVG (check the last closed bar) ──
   if(CountPositions() > 0) return;  // Only one position at a time.

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ── Long Entry ──
   if(g_pendingLong && barLow <= g_longFVG_top && barClose >= g_longFVG_bottom)
   {
      double entryPrice = ask;
      double sl         = g_longFVG_bottom - InpSLBufferPts * point;
      double riskPts    = entryPrice - sl;
      double tp         = entryPrice + riskPts * InpRRRatio;

      // Normalize prices.
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      double lots = CalcLotSize(riskPts);

      if(trade.Buy(lots, _Symbol, entryPrice, sl, tp, "SB Long"))
         Print("Long entry: lots=", lots, " entry=", entryPrice, " SL=", sl, " TP=", tp);
      else
         Print("Long entry FAILED: ", GetLastError());

      g_pendingLong = false;
   }

   // ── Short Entry ──
   if(g_pendingShort && barHigh >= g_shortFVG_bottom && barClose <= g_shortFVG_top)
   {
      double entryPrice = bid;
      double sl         = g_shortFVG_top + InpSLBufferPts * point;
      double riskPts    = sl - entryPrice;
      double tp         = entryPrice - riskPts * InpRRRatio;

      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      double lots = CalcLotSize(riskPts);

      if(trade.Sell(lots, _Symbol, entryPrice, sl, tp, "SB Short"))
         Print("Short entry: lots=", lots, " entry=", entryPrice, " SL=", sl, " TP=", tp);
      else
         Print("Short entry FAILED: ", GetLastError());

      g_pendingShort = false;
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── Daily reset check (uses GMT internally for EST day boundary) ──
   CheckDailyReset();

   // ── Update daily loss flag ──
   if(!g_dailyLossHit && IsDailyLossHit())
   {
      g_dailyLossHit = true;
      Print("DAILY LOSS LIMIT HIT – halting trading for today.");
      if(CountPositions() > 0)
         CloseAllPositions("Daily Loss Limit");
   }

   // ── New-bar gate: only process strategy once per bar ──
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;

   // ── Run the core strategy logic ──
   ProcessStrategy();
}
//+------------------------------------------------------------------+
