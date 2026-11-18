# **Fortfolio 2.0 \- Master Product Requirements Document (Technical & Financial Specifications)**

This document integrates the complete architecture, business logic, defense protocols, database schemas, and interface specifications for the **Fortfolio** (The Fortress 2.0) application.

## **1\. Overview & System Architecture**

* **Frontend (React Native / Expo):** A thin client responsible strictly for rendering. It includes a global language context for dynamic localization (Hebrew/English with automatic RTL/LTR layout adjustment) and a strict dark mode UI aesthetic.  
* **Backend (Python FastAPI):** A middleware server interacting with Yahoo Finance and other market data providers. It features an in-memory caching mechanism (15-minute TTL) to prevent Thundering Herd issues and HTTP 429 Rate Limits. It automatically handles TASE stocks (appending .TA) and includes a ping health-check service to prevent cold starts.  
* **Database (Supabase \- PostgreSQL):** The absolute Single Source of Truth. A relational database supporting ACID properties, featuring core tables and a central calculation engine via the ui\_pipeline\_metrics View, which handles window functions for asset weights, currency normalization, and financial alert statuses.

  ## **2\. Investment Layers & Generic Allocation DNA**

The application is fully generic, allowing users to select or define their asset allocation model during the initial Onboarding Wizard (supporting presets like Low, Medium, High, or a Custom configuration where layer sum totals strictly equal 100%). The baseline model follows the 70/20/10 protocol:

| Layer | Strategic Purpose | UI Indicators | Defense / Action Protocol |
| :---- | :---- | :---- | :---- |
| **Core (70%)** | Stability anchor (Bogle). Index tracking and home bias. | Allocation deviation (Current vs. Target weight). | **Eternal Hold.** No sell orders. No stop-losses permitted under any market condition. |
| **Satellite (20%)** | Generating Alpha from macro and sectoral trends. | Distance from trailing stop, 52-week drawdown, SMA200 (read-only macro context). | **Trailing Stop-Loss (12%):** A strict 12% trailing stop evaluated on weekly market close (Weekly Close) for all satellite assets. Generates a SELL\_TRIGGERED output. |
| **Quality (10%)** | Economic moats and quality (Buffett). Stable capital growth and ROIC. | Drawdown percentage, fundamental status (Hold / Audit). | **Kill Switch (15%):** No technical stop-losses. A drawdown of 15% or greater triggers a red alert: \[FUNDAMENTAL AUDIT REQUIRED\] demanding deep financial review (Moat/ROIC/Debt). |

## **3\. Financial Engine & Data Calibration**

* **Auto-Calibration Mechanism:** Solves broken Yahoo Finance data issues (e.g., index values shown instead of ETF unit prices). The user inputs the "Total Bank Value" in the frontend, and the system computes an automatic calibration\_factor multiplied against raw prices to maintain precise percentage tracking without distorting portfolio valuation.  
* **Multi-Currency Normalization:** The backend samples USD/ILS exchange rates. TASE stock prices quoted in Agorot (.TA, ILA, ILX) are automatically divided by 100 in the SQL View to output clean ILS values, which are then normalized into base currency for accurate portfolio weight calculations, displaying proper currency symbols (₪ / $) in the UI.  
* **The 30K Rule (No-Margin Policy):** Strict exclusion of 30,000 ILS (Emergency Credit Line) from any active buying power calculation, blocking any transaction that would create a negative cash balance.

  ## **4\. Database Schema & Supabase View Logic**

The database is managed in Supabase using rigid relational tables, offloading heavy computations to a centralized SQL View.

### **4.1 Core Table Schemas**

* portfolio\_assets: Tracks ticker symbols, asset layers, unit quantities, current prices, 52-week highs, currencies, and calibration factors.  
* ops\_log: The Single Source of Truth ledger recording every BUY, SELL, DEPOSIT, EXCHANGE, and DIVIDEND transaction with ISO timestamps and user memos.  
* risk\_profiles: Manages stop configurations, peak prices for watermark tracking, and order types.

  ### **4.2 Supabase View Logic (ui\_pipeline\_metrics)**

Supabase computes the following in real-time:

1. **Price Normalization:** (current\_price \* calibration\_factor) / 100 for TASE tickers (.TA).  
2. **Market Value:** Calculates individual asset values and total portfolio net asset value.  
3. **Window Functions:** Computes layer weights relative to the total portfolio (current\_weight\_pct).  
4. **Defense Status Generation:** Outputs automated control strings such as SELL\_TRIGGERED (Satellites) and FUNDAMENTAL\_AUDIT\_REQUIRED (Quality).

   ## **5\. UI/UX & User Flow**

* **Onboarding Wizard:** An initial setup screen where the user defines their base currency, chooses their allocation model (presets or Custom sum-to-100%), and sets liquidity rules (including the 30,000 ILS exclusion and a 1,500 ILS operational cash buffer).  
* **Global Header:** Features a live language toggle (Hebrew/English with automatic RTL/LTR layout adjustment), a theme toggle (Light/Dark mode), and an action dropdown for JSON backup export/import and clipboard copying.  
* **Portfolio Tab:** A clean, segmented list filtered by investment layers (Core, Satellites, Quality) showing split-format unit quantities and valuations.  
* **Ambush Radar Tab:** Tracks potential assets prior to acquisition. Displays 52-week drawdown, tactical indicators, and **SMA200 as a read-only macro context**. An entry trigger fires when a pullback crosses 7%.  
* **Knowledge Center:** Embedded throughout the application using small (i) icons next to financial terms (e.g., Drawdown, Trailing Stop, ROIC), opening instant definitions from "The Fortress" lexicon.

  ## **6\. Management Engines & Microservices**

* **DSVE (Data Sync & Valuation Engine):** A background service polling Yahoo Finance (with a 15-minute cache) to calculate updated portfolio valuations.  
* **FTRE (Fortress Tactical Rebalancing Engine):** Computes allocation drift, triggering rebalance recommendations only when a layer's absolute drift exceeds 2.5%.  
* **Core Shield (-5.0%):** An emergency rule where a Core layer deficit exceeding 5% halts purchases in other layers and prompts satellite trimming to reinforce the Core.  
* **Ambush & Overlap Scanner:** An audit engine exploding ETFs into underlying holdings to ensure true exposure to any single stock does not breach a hard 5.0% concentration cap.  
* **Behavioral Gap Engine (BGE):** A reflection module calculating the exact USD/ILS dollar difference between the active portfolio value and a passive VOO "Buy & Hold" benchmark (displaying Alpha vs. Behavioral Drag).  
* **Chat Room (FTI):** An on-demand intelligence terminal supporting natural commands (\!ניתוח\_עומק, \!EHA) to fetch LLM-driven sentiment on SEC filings and macroeconomic events.

