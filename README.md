ICT Silver Bullet – Algorithmic Trading Strategy

## Overview

This repository contains a complete implementation of the **ICT (Inner Circle Trader) Silver Bullet** model as an automated trading strategy, provided in two languages:

| File | Platform | Language |
|------|----------|----------|
| `ICT_SilverBullet_Strategy.pine` | TradingView | Pine Script v5 |
| `ICT_SilverBullet_EA.mq5` | MetaTrader 5 | MQL5 |

Both implementations target **Nasdaq (NQ)** and **Gold (XAU)** instruments.

## Strategy Rules

### Session Window
- **Active only** during the New York AM Silver Bullet session: **10:00 – 11:00 AM EST**.
- All timezone offsets are configurable (defaults to UTC−5 for Eastern Standard Time).

### Entry Logic (5-step sequence)
1. **Liquidity Sweep** – Price wicks beyond a recent swing high (buy-side) or swing low (sell-side) and closes back inside.
2. **Market Structure Shift (MSS)** – A displacement candle confirms the shift (body > 50% of ATR).
3. **Fair Value Gap (FVG)** – A 3-candle imbalance is identified on the displacement leg.
4. **Retracement Entry** – Price returns into the FVG zone, triggering the trade.
5. **Order Execution** – Market entry with pre-calculated SL and TP.

### Risk Management
| Rule | Default |
|------|---------|
| Stop Loss | Just beyond the opposite side of the FVG (configurable buffer) |
| Take Profit | 1:2 Risk-Reward ratio |
| Daily Loss Limit | 2% of account equity – halts all trading for the day |
| Time Exit | All open positions closed at **11:15 AM EST** |

## Setup

### Pine Script (TradingView)
1. Open [TradingView](https://www.tradingview.com) → Pine Editor.
2. Paste the contents of `ICT_SilverBullet_Strategy.pine`.
3. Click **Add to Chart** → open the Strategy Tester tab to backtest.
4. Adjust inputs (EST offset, swing lookback, R:R ratio, daily loss %) in the Settings panel.

### MQL5 (MetaTrader 5)
1. Open MetaTrader 5 → MetaEditor.
2. Create a new Expert Advisor and paste the contents of `ICT_SilverBullet_EA.mq5`.
3. Compile (F7) — should compile with **zero errors**.
4. Attach to an NQ or XAU chart and configure input parameters.
5. Use the Strategy Tester for backtesting.

## Configuration Parameters

### Pine Script Inputs
| Parameter | Default | Description |
|-----------|---------|-------------|
| EST UTC Offset | −5 | Timezone offset (−5 winter / −4 summer) |
| Session Start Hour | 10 | Silver Bullet window start (EST) |
| Session End Hour | 11 | Silver Bullet window end (EST) |
| Time-Exit Minutes | 15 | Minutes past session end for forced exit |
| Swing Detection Lookback | 5 | Bars for pivot detection |
| Risk:Reward Ratio | 2.0 | Take-profit multiplier |
| Max Daily Loss % | 2.0 | Daily drawdown guardrail |
| SL Buffer (ticks) | 0.5 | Additional SL distance beyond FVG |

### MQL5 Inputs
| Parameter | Default | Description |
|-----------|---------|-------------|
| InpESTOffset | −5 | Timezone offset |
| InpSessionStart | 10 | Session start hour (EST) |
| InpSessionEnd | 11 | Session end hour (EST) |
| InpTimeExitMin | 15 | Time-exit minutes past session end |
| InpSwingLen | 5 | Swing detection lookback bars |
| InpRRRatio | 2.0 | Risk:Reward ratio |
| InpMaxDailyLoss | 2.0 | Max daily loss % |
| InpSLBufferPts | 5.0 | SL buffer in points |
| InpRiskPercent | 2.0 | Risk per trade % |
| InpMagicNumber | 20240101 | EA order identification |
