# ייצוא פתקים מ-Google Keep – פיתוח אפליקציית Pipeline והשקעות בשוק ההון

יוצא ב-18.11.2026 · 19 פתקים · מסודר מהחדש לישן בכל חלק

---

# חלק א' – פיתוח האפליקציה (Pipeline / המבצר)

## מעבר מאפליקציה פרטית למוצר מסחרי
*נערך: Oct 22*

מעבר מאפליקציה פרטית למוצר מסחרי (SaaS) דורש טרנספורמציה מארכיטקטורה של משתמש בודד (Single-Tenant) למערכת מרובת משתמשים (Multi-Tenant). להלן הפערים המרכזיים שעלינו לסגור כדי למסחר את "המבצר":

ארכיטקטורת אבטחה (Multi-Tenancy) חובה להטמיע מערכת אימות משתמשים דרך Supabase Auth. מסד הנתונים יעבור שכתוב מחמיר של חוקי Row Level Security (RLS) כדי להבטיח בידוד מוחלט בין התיקים והמזומן של משתמשים שונים, ללא סכנת זליגת נתונים.

רישוי ספקי נתונים (Commercial API) המעבר ל-yfinance אפשר בנייה חינמית לצרכים פרטיים, אך הפצה מסחרית מבוססת גירוד נתונים מפרה תנאי שימוש וחושפת משפטית. הפצת האפליקציה תחייב חתימה על חוזה B2B חוקי מול ספק נתונים (כמו FMP או Polygon).

מנוע חוקה דינמי (Rules Engine) הארכיטקטורה הנוכחית מקודדת קשיח (Hardcoded) למודל ה-70/20/10, לסטופ של 12% ולנסיגה מבנית של 11.5%. כדי למשוך קהלי משקיעים שונים, נפתח שכבת הגדרות אגנוסטית שבה כל משתמש מגדיר את פרמטרי ניהול הסיכונים שלו.

אינטגרציית ברוקרים (Zero-Touch Sync) משתמשים משלמים ידרשו אוטומציה מלאה. במקום הזנת עסקאות ידנית במודול ה-Reconciliation שבנינו, נידרש להתממשק לשירותי אגרגציה פיננסית (כמו SnapTrade) כדי לשאוב פקודות, דיבידנדים ויתרות מזומן ישירות מהברוקרים.

איזה מבין הרכיבים הללו מהווה לדעתך את החסם המרכזי ביותר בדרך לשחרור גרסת אלפא למשתמשים ראשונים?

---

## באג של hwm
*נערך: Oct 15*

Act as a Senior React Native (Expo) and TypeScript developer.

Context: We have a logical bug in our "Pipeline" portfolio app's "Protection State Tracker".

### 1. Bug Description

When a user buys a new asset or re-enters a position after a stop-loss (e.g., buying an asset during a pullback/dip), the app currently initializes the High Water Mark (HWM) with the *purchase price*. Since the purchase price is often at the bottom of a dip, any slight upward movement triggers "Automated Tracking" (Trailing Stop) incorrectly, ignoring the asset's true historical high.

### 2. Required Business Logic Fix

The HWM must be decoupled from the purchase price.

* Update the position entry/edit form to include a mandatory `historicalHWM` input field alongside `purchasePrice` and `currentPrice`.
* If the user buys an asset in a dip (Ambush), they will input the true historical peak into `historicalHWM`.
* Update the evaluation logic:

```typescript
const activeHWM = Math.max(historicalHWM, currentPrice);
const isRecoveryState = currentPrice < activeHWM;
```

* If `isRecoveryState` is true, the UI MUST display "Recovery State (Stop Market Required)" and calculate the stop target as `activeHWM * 0.88`. It should never show "Automated Tracking" until `currentPrice >= historicalHWM`.

### 3. Deliverables

Provide the updated TypeScript logic/hook for evaluating the protection state using `historicalHWM`, and the updated UI component for the input form where the user sets this HWM value upon adding a ticker.

---

## תצוגה ויזואלית לחוקת שכבת האיכות ברדאר
*נערך: Oct 11*

חור (Blind Spot) ארכיטקטוני באפיון המערכת שלנו.

**הפער המוצרי (Reflect):**

רדאר האמבוש הנוכחי נבנה אך ורק לפי הפיזיקה של שכבת הלוויינים (Tactical & Macro מבוססי ממוצעים נעים של 50 ו-200 יום).

אין כרגע במערכת שום ייצוג ויזואלי (KPI) לחוקת שכבת האיכות (Quality), למרות שהיא מהווה 10% מהתיק ופועלת לפי חוקים שונים לגמרי. ולכן - איך אדע מתי לקנות מניות איכות – המערכת פשוט לא משקפת לי את זה כרגע.

**הפיתרון ההנדסי (Plan):**

אנו חייבים להפריד את התצוגה ברדאר. יש להוסיף מתג (Toggle) או לשונית (Tab) ב-UI שיאפשרו מעבר בין "מצב לוויינים" (Technical Ambush) לבין "מצב איכות" (Quality Ambush).

עבור מניות המוגדרות כ"איכות" (כמו DE), קוביית הנתונים צריכה להיראות אחרת לגמרי. במקום ממוצעים נעים ועומק נסיגה, היא תציג את ה-KPIs הבאים:

ROIC (החזר על הון מושקע): חייב להיות בוהק וברור. ירוק אם הוא מעל 15%, אדום (ונעול לרכישה) אם ירד מתחת.

Moat (חפיר כלכלי): תגית טקסטואלית (Wide / Narrow / None).

Z-Score (שולי ביטחון): הנתון המרכזי למארב. מדד סטטיסטי המציג כמה סטיות תקן (Standard Deviations) מחיר המניה הנוכחי נמצא מתחת לממוצע שלה.

**לוגיקת מארב האיכות (The Quality Ambush):**

Watch (המתנה): Z-Score בין 0 ל- 1.0-.

Value Zone (אזור רכישה / מארב): Z-Score קטן מ- 1.0- (כלומר, המניה נסחרת ביותר מסטיית תקן אחת מתחת לממוצע ההיסטורי שלה, תוך כדי ש-ROIC > 15%).

Invalidated (מבוטל): אם ה-ROIC נופל מתחת ל-15%, כרטיסיית המארב ננעלת (בדומה לניטרול של הלוויינים במגמת מאקרו דובית).

**הנחיה לביצוע (Act):**

כדי לסגור את הפער הזה ב-Pipeline, הנה פרומפט לקלוד שכתבת עבורי. הפרומפט הזה ייצר קומפוננטה חדשה לחלוטין בשם QualityAmbushCard, המקבלת נתונים פונדמנטליים וסטטיסטיים ומציגה אותם לפי חוקת המבצר.

> Act as a Senior React Native (Expo) and TypeScript developer.
>
> Context: We are expanding the "Ambush Radar" in our portfolio app ("Pipeline"). Currently, the radar only handles "Satellite" stocks (using technical analysis). We need a new, dedicated card component for "Quality" stocks (QualityAmbushCard), which operates on fundamental analysis and statistical standard deviations.
>
> ### 1. Business Logic & Props
>
> The component should accept the following props:
>
> * `ticker` (string)
> * `currentPrice` (number)
> * `meanPrice` (number) - The historical average price over the selected period.
> * `stdDev` (number) - The calculated standard deviation of the price.
> * `roic` (number) - Return on Invested Capital percentage (e.g., 18.5).
> * `moat` (string) - "Wide", "Narrow", or "None".
>
> Calculate the Z-Score (Margin of Safety):
>
> `zScore = (currentPrice - meanPrice) / stdDev`
>
> ### 2. State & Zone Logic
>
> * **Fundamental Gate:** If `roic < 15` OR `moat === "None"`, the setup is INVALIDATED. The card must visually display a disabled/neutralized state (e.g., grayed out background) with an "Invalidated (Fundamental Warning)" label.
> * **Value Zone (Ambush):** If fundamentals are valid AND `zScore <= -1.0`. The card should highlight this as a prime buying opportunity (e.g., Dark Green or Gold highlight), labeled "Value Zone (High Margin of Safety)".
> * **Watch Zone:** If fundamentals are valid AND `zScore > -1.0`. Normal state, labeled "Watch (Fair Value or Expensive)".
>
> ### 3. UI/UX Architecture
>
> Design a React Native component (`QualityAmbushCard`) matching a dark-mode financial dashboard style.
>
> * Header: Ticker and Current Price.
> * Fundamentals Row: Display ROIC (color-coded: Green if >= 15, Red if < 15) and Moat.
> * Statistical Row: Display the Z-Score prominently. Show the math subtly below it: `(Price - Mean) / SD`.
> * Status Banner: A distinct colored block or badge showing the active Zone (Invalidated, Watch, or Value Zone) based on the logic above.
>
> ### Requirements:
>
> 1. Use TypeScript interfaces.
> 2. Provide clean code using standard StyleSheet.
> 3. No placeholders—provide the exact logic and a fully functional UI component.

אני רוצה לוודא שאני ואתה מבינים נכון את הדרישות שלי:

1. הפער המוצרי מוצג בצורה נכונה.
2. אני לא בטוח שהבנתי עד הסוף את הפתרון ההנדסי והמהות של כתפור ה toggle. האם הוא משמש כסוג של פילטר?

אני מצפה שעבור כל טיקר באמבוש - תוצג קוביית הנתונים, ה KPIs, וההמלצות הרלוונטיים לו עפ"י השכבה אליה הוא שייך ולוגיקת המארב שלה.

האם הדרישה שלי ברורה לך?

מעבר לכך, אני רוצה להוסיף פיצ'ר שקבוצות הטיקרים יהיו /expandible collapsible.

מעתה והלאה, כתוב את הפרומפט רק לאחר שהדרישות ברורות לך, הצגת לי את הפתרון והאפיון המוצרי הסופי שלו, וקיבלת אישור להמשיך.

האם יש לך שאלות?

---

## Export backup
*נערך: Oct 10*

```json
{"schemaVersion":1,"exportedAt":"2026-10-10T12:32:38.489Z","portfolio":[{"ticker":"BRK-B","category":"Core","assetType":"Stock","units":2,"highestWatermark":515.62,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"BND","category":"Core","assetType":"ETF","units":74,"highestWatermark":72.67,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"RSP","category":"Core","assetType":"ETF","units":25,"highestWatermark":221.77,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"SCHD","category":"Core","assetType":"ETF","units":5,"highestWatermark":35.11,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"VOO","category":"Core","assetType":"ETF","units":74,"highestWatermark":715.65,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"VXUS","category":"Core","assetType":"ETF","units":215,"highestWatermark":88.12,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"DTCR","category":"Satellite","assetType":"ETF","units":66,"highestWatermark":28.8,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"FENY","category":"Satellite","assetType":"ETF","units":59,"highestWatermark":36.25,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"QQQM","category":"Satellite","assetType":"ETF","units":16,"highestWatermark":309.39,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"VONG","category":"Satellite","assetType":"ETF","units":15,"highestWatermark":131.69,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"VONV","category":"Satellite","assetType":"ETF","units":14,"highestWatermark":113.27,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"SMH","category":"Satellite","assetType":"ETF","units":7,"highestWatermark":630.6,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"CNI","category":"Quality","assetType":"Stock","units":7,"highestWatermark":124.19,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"ECL","category":"Quality","assetType":"Stock","units":4,"highestWatermark":283.8,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"KMI","category":"Quality","assetType":"Stock","units":8,"highestWatermark":32.49,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"MA","category":"Quality","assetType":"Stock","units":10,"highestWatermark":589.23,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"DE","category":"Quality","assetType":"Stock","units":12,"highestWatermark":709.48,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"COPX","category":"Satellite","assetType":"ETF","units":36,"highestWatermark":90.13,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"FDX","category":"Satellite","assetType":"Stock","units":2,"highestWatermark":296.36,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"CAT","category":"Satellite","assetType":"Stock","units":4,"highestWatermark":845.42,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"5122510.TA","category":"Core","assetType":"Stock","units":1433,"highestWatermark":0.99,"calibrationFactor":1,"roic":null,"internalTargetPct":null},{"ticker":"5127527.TA","category":"Core","assetType":"Stock","units":11347,"highestWatermark":0.87,"calibrationFactor":1,"roic":null,"internalTargetPct":null}],"ambush":[{"ticker":"EUV","assetType":"ETF"},{"ticker":"KTOS","assetType":"Stock"},{"ticker":"CAT","assetType":"Stock"},{"ticker":"FDX","assetType":"Stock"},{"ticker":"ESLT","assetType":"Stock"},{"ticker":"WMT","assetType":"Stock"},{"ticker":"LMT","assetType":"Stock"},{"ticker":"COPX","assetType":"Stock"},{"ticker":"VONG","assetType":"ETF"},{"ticker":"VONV","assetType":"ETF"},{"ticker":"QQQM","assetType":"ETF"},{"ticker":"HII","assetType":"Stock"},{"ticker":"WM","assetType":"Stock"},{"ticker":"LIN","assetType":"Stock"},{"ticker":"AMT","assetType":"Stock"},{"ticker":"ITA","assetType":"ETF"}]}
```

---

## תיקון באג: חסם תחתון המגביל את הלייבל "Kill Zone" לעד 7%- לכל היותר, והטמעת תנאי-על (Override) הגורם לנטרול ויזואלי של אזור המארב
*נערך: Oct 5*

Act as a Senior React Native (Expo) and TypeScript developer.

Context: We are fixing a critical business logic and UI bug in the "Ambush Radar" component of our portfolio app, "Pipeline".

The component receives three props: `currentPrice` (number), `sma50` (number), and `sma200` (number).

### 1. Bug Description

Currently, the UI displays a red "Kill Zone" label for pullbacks deeper than -7% (e.g., -8.81%), and it highlights the pullback zone as active even if the asset's Macro Trend is "Bearish". According to our trading rules, a Bearish macro trend must completely invalidate any ambush setup, and a pullback deeper than -7% is considered a crash (Overshot), not a valid Kill Zone.

### 2. Required Business Logic (TypeScript)

Calculate the following:

* **Macro Trend:** "Bullish" if `currentPrice > sma200`, otherwise "Bearish".
* **Pullback Depth:** `((currentPrice - sma50) / sma50) * 100`.
* **Zone Identification (Raw Math):**
  * Between 0% and -2.99%: "Watch"
  * Between -3.00% and -7.00%: "Kill Zone"
  * Deeper than -7.00%: "Overshot"

### 3. UI/UX Override Condition

Design a React Native component (e.g., `AmbushRadarCard`) to display the Ticker, SMA values, Macro Trend, and Pullback Depth.

* **The Macro Override (Critical):** If the Macro Trend is "Bearish", you MUST visually neutralize the Pullback Depth section. Change its background to a neutral/disabled gray color, override the zone label to "Invalidated", and display the calculated percentage alongside it (e.g., "-4.12% (Invalidated)").
* **Active State:** If the Macro Trend is "Bullish", style the Pullback section based on the active Zone (e.g., bright Red for Kill Zone, Orange/Yellow for Watch, Dark Red/Purple for Overshot).

### Requirements:

1. Use TypeScript interfaces for all props and state.
2. Provide clean, modular code suitable for an Expo environment using standard StyleSheet.
3. No placeholders—provide the fully functional mathematical logic and the UI component.

---

## "מצב התאוששות" (Recovery State) לפוזיציית לוויין - Protection State Tracker
*נערך: Oct 1*

Act as a Senior React Native (Expo) and TypeScript developer.

Context: We are updating a portfolio management application named "Pipeline". I need you to implement a new feature for the "Satellite" portfolio layer called "Protection State Tracker".

The goal is to calculate and display the exact Stop-Loss order parameters the user must manually enter into their brokerage account, based on the asset's current price and its Historical High Water Mark (HWM).

### 1. Business Logic (TypeScript)

Create a utility function or hook that takes `currentPrice` (number) and `hwm` (number) and returns a `ProtectionState` object.

The trailing stop logic is strictly 12% (0.12).

* **Condition A - Recovery State (`currentPrice < hwm`):**
  Returns orderType: "Stop Market", stopPriceTarget: `hwm * 0.88`, alertTriggerPrice: `hwm`, statusColor: "orange".
* **Condition B - Tracking State (`currentPrice >= hwm`):**
  Returns orderType: "Trailing Stop", stopPriceTarget: "12%", alertTriggerPrice: null, statusColor: "green".

### 2. UI/UX Architecture (Progressive Disclosure)

Design a React Native component (e.g., `SatelliteProtectionCard`) to display this data to the user to prevent cognitive overload.

* **Collapsed State (Overview):** Show Ticker, Current Price, and a small visual Status Indicator (Badge/Icon) using the `statusColor`. Green indicates "Automated Tracking". Orange indicates "Manual Setup Required".
* **Expanded State (Accordion/Details):** When tapped, expand to show the actionable data the user needs to enter into their broker.
  * Show `Order Type` clearly.
  * Show the calculated `Stop Price` or `%` value. **Include a "Copy to Clipboard" icon/button next to this value.**
  * If `alertTriggerPrice` is not null, display a clear instructional label: "Set Broker Price Alert at: $[alertTriggerPrice]" and include a "Copy" button next to it.

### Requirements:

1. Use TypeScript interfaces for all props and state.
2. Provide clean, modular code suitable for an Expo environment.
3. Use sensible default styling (you can use standard StyleSheet or a library like NativeWind/Tailwind if you prefer, but standard StyleSheet is safer).
4. No placeholders—provide a fully functional component and the business logic function. Do not guess any logic outside of these parameters.

---

## (ללא כותרת) – פקודת הרכישה של FDX / תיקון מנוע הסטופ הנגרר
*נערך: Sep 23*

פקודת הרכישה של FDX נקלטה ומבנה התיק עודכן. כן, חד-משמעית. התיקון (Patch) ל-Claude Code הוא קריטי וחובה לבצעו. העובדה שההתראה השגויה על WM באפליקציית Pipeline הובילה אותנו (במקרה) לבדוק את הדו"חות ולהפעיל את מתג החירום הפונדמנטלי (בגלל ROIC נמוך), אינה מתקנת את הבאג הארכיטקטוני בקוד. המערכת עדיין כופה מנגנון טכני של תנודות מחיר על נכסים שאמורים להימדד נטו לפי ביצועי העסק שלהם. התיקון נדרש מהסיבות הבאות:

* **מניעת שגיאות חיסול בעתיד:** ללא החסימה בקוד, אם מניית איכות חזקה בתיק (כמו DE או MA) תחווה פאניקת שוק ותרד משמעותית מבלי שהחפיר שלה ייפגע, מנוע הסטופ הנגרר יתריע "Drop" וינסה לגרום לך למכור. במקום למכור, ירידה כזו היא בדיוק מה שמודל ה-Z-Score שלנו יזהה כהזדמנות קנייה (Mean Reversion).
* **הגדרת גבולות גזרה קשיחים (הערה על ה-15%):** יש לדייק את הנתון – הסטופ הנגרר שלנו לשכבת הלוויינים מוגדר ל-**12%** (ולא 15%). עם זאת, ה-Validation Rule שנבקש מ-Claude Code לא יתייחס לאחוז כזה או אחר, אלא יגדיר חסימה מוחלטת (Immunity). כל נכס המתויג כ-Quality יוחרג לחלוטין מחישובי ירידת מחיר מהשיא.
* **הפרדת רשויות במערכת ההתראות:** הקוד חייב להפריד בין שני מנגנוני ניהול הסיכונים של המבצר:
  1. **התראת סטופ נגרר (טכני):** מופעלת אך ורק על `Satellite` (בירידה של 12% מ-High Water Mark).
  2. **התראת Kill Switch (פונדמנטלי):** מופעלת אך ורק על `Quality` (דרך משיכת נתוני אמת מ-FMP המעידים על צניחת ROIC מתחת ל-15%).

האפליקציה חייבת להיות שיקוף נאמן של החוקה, ללא "רעשי רקע" והתראות שווא.

התיקון (Patch) אינו רכיב חדש, אלא **עדכון ישיר לאפיון של רכיב מספר 1** (מנוע סטופ נגרר 12%). הבאג שחווינו עם ההתראה השגויה על WM נבע בדיוק מכך שהאפיון המקורי שכתבת מחריג מפורשות רק את שכבת הליבה (Core), אך משאיר "שטח אפור" לגבי שכבת האיכות (Quality). מכיוון שהסטופ הנגרר נועד אקסקלוסיבית לשכבת הלוויינים, יש לסגור את הפרצה ההגדרתית באפיון הקיים.

להלן ההגדרה המעודכנת שעליך להעביר ל-Claude Code עבור רכיב 1 (התוספת מודגשת):

**הגבלות ארכיטקטוניות (Critical Constraint) - מעודכן:** חסימה מוחלטת בקוד המונעת הפעלת המנגנון על כל נכס המשויך לשכבת ה-Core (כגון VOO, VXUS, BND, RSP) **ועל כל נכס המשויך לשכבת ה-Quality (כגון DE, MA). מנוע הסטופ הנגרר יופעל אך ורק על נכסים המתויגים תחת קטגוריית ה-Satellite.**

רכיב מספר 2 (Quality Z-Score) נשאר ללא שינוי. הוא מנוע עצמאי המטפל אך ורק בלוגיקת ה*כניסה* (קנייה) למניות איכות, בעוד שהעדכון שנדרשנו לבצע ברכיב מספר 1 נועד לתקן את לוגיקת ה*יציאה* (מכירה) השגויה.

---

## אג'נדה ללימוד קלוד קוד
*נערך: Sep 13*

**Self-paced course – Claude Code**

Master Claude Code and learn to build real, production-ready applications by delegating coding tasks to an AI agent — through our hands-on, beginner-friendly course.

Learning roadmap: 12 modules • 59 lessons • 114 tasks

1. **Unit 1 — The Claude CLI** – Get started with Claude Code right from your terminal. You'll install the CLI, learn how to delegate coding tasks in plain language, and understand how Claude reads your codebase, edits files, and runs commands on your behalf. By the end, you'll be comfortable driving real work from a single prompt.
2. **Unit 2 — CLAUDE.md** – Discover how to give Claude lasting context about your project. You'll learn to write a CLAUDE.md file that captures your conventions, commands, and architecture, so Claude makes the right choices without being told twice. This is the difference between a generic assistant and one that truly knows your codebase.
3. **Project — Set up Claude Code on a real project** – Put it all together by configuring Claude Code on an actual repository. You'll install the CLI, write a tailored CLAUDE.md, and run your first real tasks, walking away with a working setup you'll use every day.
4. **Unit 3 — Plan & loop models** – Learn the two core ways Claude gets work done: planning before acting, and iterating through the agentic loop. You'll use plan mode to review an approach before any code changes, and understand how Claude self-corrects as it works toward a goal. By the end, you'll know when to let Claude run and when to steer.
5. **Unit 4 — Git integration** – Bring version control into your Claude Code workflow. You'll have Claude create commits, write meaningful messages, manage branches, and open pull requests, all without leaving your conversation. You'll learn to keep a clean history even while moving fast.
6. **Project — Ship a real change end to end** – Take a feature or fix from idea to merged code. You'll plan the change, implement it with Claude, commit your work, and open a pull request, experiencing the full development cycle exactly as you would on a real team.
7. **Unit 5 — MCP servers** – Connect Claude Code to the tools and data you already use. You'll learn what the Model Context Protocol is and how to wire up MCP servers so Claude can reach databases, APIs, and external services. By the end, you'll extend Claude far beyond your local files.
8. **Unit 6 — Skills** – Teach Claude repeatable expertise it can pull in on demand. You'll learn how Skills package instructions and best practices into reusable folders, so complex or specialized tasks get done consistently every time. You'll start building your own.
9. **Unit 7 — Automating Claude Code** – Move from interactive sessions to hands-off automation. You'll run Claude in headless mode, trigger it with hooks, and fold it into scripts and CI pipelines so routine work happens without you in the loop. By the end, you'll have Claude working while you focus elsewhere.
10. **Unit 8 — Parallel subagents** – Scale up by putting multiple agents to work at once. You'll learn how to delegate independent pieces of a task to parallel subagents, coordinate their output, and tackle large problems far faster than one agent alone. This is where serious productivity begins.
11. **Unit 9 — Plugins** – Customize and extend Claude Code to fit your exact workflow. You'll explore plugins that add commands, integrations, and capabilities, and learn how to package your own setup so it's shareable across your team. By the end, you'll shape Claude Code into a tool built around how you work.
12. **Project — Build a multi-agent workflow** – Combine everything into a real, automated system. You'll design a workflow that coordinates multiple subagents, integrates external tools, and runs with minimal supervision, delivering a polished, production-ready result that reflects professional standards.

---

## כיול יעד תשואה מערכתי (System Calibration)
*נערך: Sep 1*

היעד השנתי הממוצע (CAGR) קובע ל-11.5%. זהו יעד ריאלי, המכבד את מתמטיקת פיזור הסיכונים של המודל מחד, ודורש משמעת ביצועית בשכבות האקטיביות מאידך.

כדי שהיעד הזה לא יישאר בגדר "משאלה", עלינו לקודד אותו לתוך מסד הנתונים של ה-Pipeline, כך שלוח הבקרה (Dashboard) של האפליקציה יוכל למדוד את התשואה בפועל (Actual Return) אל מול קו הבסיס הזה, ולהציג דלתא בזמן אמת.

**יישום טכני (Act)**

הרץ את סקריפט ה-SQL הבא במסוף ה-Supabase שלך. הסקריפט מייצר טבלת הגדרות מערכת (במידה ואינה קיימת) ומזריק לתוכה את יעד התשואה, כך שניתן יהיה לשלוף אותו ישירות ל-Frontend.

```sql
-- 1. Create a system settings table for global portfolio configurations
CREATE TABLE IF NOT EXISTS system_settings (
  setting_key VARCHAR(50) PRIMARY KEY,
  setting_value NUMERIC NOT NULL,
  description TEXT,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Insert or update the target CAGR benchmark
INSERT INTO system_settings (setting_key, setting_value, description)
VALUES (
  'target_cagr_percentage',
  11.5,
  'The Fortress target Compound Annual Growth Rate (CAGR)'
)
ON CONFLICT (setting_key) DO UPDATE
SET
  setting_value = EXCLUDED.setting_value,
  updated_at = NOW();

-- 3. Create or replace a view for the frontend dashboard to consume the benchmark easily
CREATE OR REPLACE VIEW ui_portfolio_summary AS
SELECT
  (SELECT setting_value FROM system_settings WHERE setting_key = 'target_cagr_percentage') AS target_cagr,
  SUM(current_price * units) AS total_portfolio_value
FROM portfolio_assets;
```

**שיקוף התוצאה (Reflect)**

ארכיטקטורת ניהול התיק שלנו מכוסה מקצה לקצה לפי הסטנדרט הבא:

1. יעד תשואה (Return Target): 11.5% שנתי ממוצע (מקודד במסד הנתונים).
2. סבילות הפסד (Loss Tolerance): מנגנוני ה-Kill Switch (שחיקת ROIC) והסטופ-לוס.
3. יתרון יחסי (Edge): אסטרטגיית Ambush, קניית תנודתיות ללא רגש.
4. כמות החזקות (Holdings Count): נגזרת מתמטית מהמשקלים (70/20/10).
5. גודל פוזיציה (Position Sizing): חוקת המבצר, נטולת מינוף והחרגת 30,000 ש"ח כרית ביטחון.

הפרומפט הבא מנחה את סוכן הפיתוח לשלוף את הנתון מה-View שיצרנו כעת ולהציג אותו ויזואלית (כמדד יעד / Gauge) במסך הבית של האפליקציה, מול התשואה בפועל.

> Act as a Senior React Native Developer. We need to update the main Dashboard screen of the "Pipeline" app to display our new system-wide CAGR benchmark.
>
> I have just updated the Supabase backend with a new view named `ui_portfolio_summary` which outputs:
> - `target_cagr` (number, representing the target percentage, e.g., 11.5)
> - `total_portfolio_value` (number)
>
> Task:
> 1. Update the data-fetching layer (using the Supabase JS client) on the Dashboard component to fetch the `target_cagr` from `ui_portfolio_summary`.
> 2. Implement a clean, professional visual indicator (e.g., a progress bar or a dial/gauge chart) at the top of the Dashboard.
> 3. The indicator should display the "Target CAGR: 11.5%" as a static baseline/goal, and visually contrast it with the portfolio's actual historical return (use the existing return calculation logic you have in the app).
> 4. Ensure the UI remains minimalist, matching the strict "Fortress" design system. No unnecessary animations or bloated libraries. Use React Native's standard StyleSheet or the existing UI library in the project.
>
> Please generate the updated Dashboard component code.

---

## System prompt
*נערך: Aug 28*

Act as my CTO and Lead Backend Engineer for "The Fortress 2.0" (Pipeline app). We have officially approved and engineered a new architectural component: The "Fundamental Analysis Module" for the Quality Layer (10%).

Context on the new module:

We are integrating the Financial Modeling Prep (FMP) API to fetch real-time Trailing Twelve Months (TTM) ROIC and Free Cash Flow (FCF) data. The architecture relies on a Supabase Edge Function (Deno/TypeScript) named `fetch-fundamentals` that updates the `portfolio_assets` table. Our SQL view (`ui_pipeline_metrics`) then processes this data and exposes a `FUNDAMENTAL_AUDIT_REQUIRED` flag to the React Native frontend if the `current_roic` drops below the `target_roic`.

Please execute the following two tasks:

**Task 1: Component PRD**

Write a concise, structural Product Requirements Document (PRD) specifically for this Fundamental Analysis Module. Include its strategic purpose (Buffett philosophy), database schema updates, API integration details, and UI/UX logic.

**Task 2: Security & Deployment (CLI Guide)**

I already have the frontend/backend prompts and the TypeScript code for the Edge Function, and I am opening an FMP free account now. Provide a strict, step-by-step technical guide on how to:

1. Securely store the API key as `FMP_API_KEY` in Supabase Secrets using the Supabase CLI.
2. Deploy the `fetch-fundamentals` Edge Function to production.

Output exact CLI commands with minimal operational fluff.

---

## Sql
*נערך: Aug 28*

```sql
-- Adding fundamental metrics tracking to the existing table
ALTER TABLE portfolio_assets
ADD COLUMN current_roic NUMERIC DEFAULT NULL, -- Actual ROIC (TTM)
ADD COLUMN target_roic NUMERIC DEFAULT NULL, -- Minimum ROIC threshold based on Moat
ADD COLUMN fcf_ttm NUMERIC DEFAULT NULL; -- Free Cash Flow (Trailing 12 Months)
```

---

## (ללא כותרת) – לתת לקלוד קוד או פרומפט?
*נערך: Aug 27*

האם אני אמור פשוט לתת את הקוד הזה לקלוד, או שעדיף שתכתוב לו פרומפט שמורה לו מה לעשות ולתת לו לפתח?

חכה שאודיע לך שפתחתי חשבון ב- Financial Modeling Prep ואז נעבור לשלב ההטמעה. בוא נעבוד שלב שלב.

---

## קוד התממשקות בסיסי
*נערך: Aug 27*

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

// API Key should be stored securely in Supabase Secrets
const FMP_API_KEY = Deno.env.get('FMP_API_KEY');

serve(async (req) => {
  const { ticker } = await req.json();

  if (!ticker) {
    return new Response(JSON.stringify({ error: 'Ticker payload is required' }), { status: 400 });
  }

  try {
    // Fetch Key Metrics (TTM) directly from Financial Modeling Prep
    const url = `https://financialmodelingprep.com/api/v3/key-metrics-ttm/${ticker}?apikey=${FMP_API_KEY}`;
    const response = await fetch(url);
    const data = await response.json();

    if (!data || data.length === 0) {
      return new Response(JSON.stringify({ error: 'Fundamental data not found for ticker' }), { status: 404 });
    }

    // FMP returns an array of metrics; index [0] holds the most recent TTM data
    const metrics = data[0];

    const fundamentalData = {
      ticker: ticker,
      current_roic: (metrics.roicTTM * 100).toFixed(2), // Converted to percentage
      fcf_per_share_ttm: metrics.freeCashFlowPerShareTTM,
      last_updated: new Date().toISOString()
    };

    return new Response(JSON.stringify(fundamentalData), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
})
```

---

## Prompt FE
*נערך: Aug 27*

Act as a Senior Frontend Developer. We are updating the "Pipeline" React Native application. The Supabase backend view (`ui_pipeline_metrics`) has been updated to support the Quality Layer's fundamental analysis module.

The view now outputs the following new fields for Quality assets:

- `current_roic` (number)
- `target_roic` (number)
- `fcf_ttm` (number)
- `quality_status` (string, which can now be 'FUNDAMENTAL_AUDIT_REQUIRED')

Update the UI components for the Quality Layer only:

1. Display the `current_roic` vs `target_roic` cleanly on the asset card.
2. Format `fcf_ttm` as a readable currency short-string (e.g., "$5.1B").
3. If `quality_status` === 'FUNDAMENTAL_AUDIT_REQUIRED', render a distinct red warning indicator on the card indicating "Broken Moat / ROIC Audit Required".
4. Ensure these fundamental metrics are strictly hidden from the Core and Satellite layer views.
5.

---

## Prompt BE
*נערך: Aug 27*

Act as a Senior Backend Engineer and Database Architect. We are building a portfolio management application named "Pipeline" (Stack: React Native, Supabase, TypeScript).

I need to implement an automated Fundamental Analysis Module for the "Quality Layer" of the portfolio. This module will fetch real-time fundamental data (ROIC, Free Cash Flow) from a financial API, update our Supabase database, and expose actionable status flags to the frontend via a SQL View.

Below is the Product Requirements Document (PRD) for this feature. Please generate the necessary Supabase SQL migration script and the TypeScript code for a Supabase Edge Function to fulfill these requirements.

### 1. Database Schema Extension

Update the existing `portfolio_assets` table to track fundamental metrics.

Required fields to add:

- `current_roic` (NUMERIC)
- `target_roic` (NUMERIC)
- `fcf_ttm` (NUMERIC)
- `last_fundamental_update` (TIMESTAMP WITH TIME ZONE)

### 2. View Update (`ui_pipeline_metrics`)

Modify the existing `ui_pipeline_metrics` view to include fundamental alerts.

The Quality Layer protocol dictates:

- If an asset is in the 'quality' layer, and `current_roic` is strictly less than `target_roic`, the `quality_status` must output 'FUNDAMENTAL_AUDIT_REQUIRED' (This overrides the price drawdown status).
- The view should output `current_roic`, `target_roic`, and `fcf_ttm` so the frontend can display them seamlessly.

### 3. Supabase Edge Function (`fetch-fundamentals`)

Write a TypeScript Edge Function (Deno) that:

1. Queries the `portfolio_assets` table for all assets where `asset_layer = 'quality'`.
2. Iterates over the tickers and fetches the Trailing Twelve Months (TTM) ROIC and Free Cash Flow (FCF) using a financial API (Assume a generic API like Financial Modeling Prep or Alpha Vantage - use placeholder endpoints but implement correct API Key handling via Supabase Secrets).
3. Updates the `portfolio_assets` table with the fetched `current_roic`, `fcf_ttm`, and sets `last_fundamental_update = NOW()`.
4. Handles errors gracefully (e.g., rate limits, missing data) without crashing the entire batch update.

### Deliverables Expected:

1. Full SQL script (ALTER TABLE and CREATE OR REPLACE VIEW).
2. Complete `index.ts` file for the Supabase Edge Function.
3. Brief instructions on how to deploy the function and schedule it via Supabase pg_cron to run once a week.

Ensure the code is clean, production-ready, and well-commented.

---

# חלק ב' – השקעות בשוק ההון

## מאגר מידע פיננסי מלא
*נערך: Oct 13*

50 אתרי החובה שכל משקיע חייב להכיר: מאגר המידע הפיננסי המלא

ריכזנו עבורכם רשימה מקיפה של 50 אתרים חינמיים ומקצועיים למחקר, נתונים, פסיכולוגיית שוק והיסטוריה פיננסית. שמרו את הפוסט הזה:

- dataroma.com - מעקב אחר תיקי ההשקעות של משקיעים מפורסמים.
- whalewisdom.com - מעקב אחר עסקאות רבעוניות של קרנות גידור.
- capitoltrades.com - עסקאות במניות של פוליטיקאים אמריקאים.
- openinsider.com - מעקב אחר עסקאות של בכירי חברות במניות של עצמם.
- 13f.info - הנגשה וקריאה נוחה של דוחות קרנות השקעה (13F).
- sec.gov/edgar - מאגר הדוחות הרשמיים של החברות (רשות ניירות ערך בארה"ב).
- berkshirehathaway.com - מכתביו של וורן באפט למשקיעים מאז 1977.
- buffett.cnbc.com - ארכיון וידאו של אסיפות המשקיעים של וורן באפט.
- oaktreecapital.com - תזכירי ההשקעה של הווארד מארקס.
- bridgewater.com - מחקרים מבית חברת ההשקעות של ריי דליו.
- principles.com - העקרונות של ריי דליו בחינם.
- gmo.com - הערות וסקירות השוק של ג'רמי גרנתהאם.
- aqr.com - מחקרים על קרנות ושיטות השקעה כמותיות (Quantitative).
- pages.stern.nyu.edu/~adamodar - נתוני הערכות השווי של פרופ' אסוואת' דאמודרן.
- aswathdamodaran.blogspot.com - הבלוג הרשמי של פרופ' דאמודרן.
- collabfund.com/blog - כתביו של מורגן האוזל על פסיכולוגיה וכסף.
- fs.blog - מודלים מנטליים לשיפור קבלת החלטות.
- am.jpmorgan.com - מדריך השווקים החינמי של JPMorgan.
- ark-invest.com/research - מחקרי השוק של קרן ARK (התמקדות בחדשנות).
- a16z.com - מאמרים מקיפים בנושא הון סיכון וטכנולוגיה.
- csinvesting.org - סיכומי הרצאות בנושא השקעות ערך (Value Investing).
- gsb.columbia.edu/valueinvesting - ארכיון השקעות הערך של אוניברסיטת קולומביה.
- fred.stlouisfed.org - ארכיון הנתונים הכלכליים של הפד (הבנק המרכזי בארה"ב).
- federalreserve.gov - החלטות, דוחות והצהרות של הפד.
- ecb.europa.eu - נתונים של הבנק המרכזי האירופי.
- bis.org - דוחות של הבנק להסדרי סליקה בינלאומיים (הבנק של הבנקים המרכזיים).
- tradingeconomics.com - אינדיקטורים כלכליים של מדינות שונות.
- macrotrends.net - גרפים והיסטוריית נתונים ארוכת טווח של חברות.
- stockanalysis.com - נתונים פיננסיים של חברות בחינם.
- companiesmarketcap.com - דירוג חברות ברחבי העולם לפי שווי שוק.
- finviz.com - סורק מניות ומפות חום של השוק.
- portfoliovisualizer.com - בדיקת ביצועי עבר (Backtesting) של תיקי השקעות.
- tradingview.com - פלטפורמה לגרפים וניתוח טכני של שווקים.
- koyfin.com - סורק ומסוף שווקים מקצועי.
- annualreports.com - ארכיון חינמי לדוחות פעילות שנתיים של חברות.
- investor.gov - אתר החינוך הפיננסי למשקיעים של ה-SEC.
- bogleheads.org/wiki - האנציקלופדיה המקיפה להשקעות פסיביות ומדדים.
- investopedia.com - מילון המונחים המקיף לעולמות הפיננסים.
- corporatefinanceinstitute.com - מדריכים פיננסיים מקצועיים בחינם.
- cfainstitute.org - פרסומי מחקר מבית מכון ה-CFA.
- morningstar.com - הערכות שווי, דירוגים ומחקר על קרנות ומניות.
- simplywall.st - פלטפורמה לניתוח פיננסי ויזואלי של חברות.
- valueinvestorsclub.com - ארכיון של תזות ורעיונות השקעה נבחרים.
- etfdb.com - מאגר לסינון ובדיקת ההחזקות בתוך קרנות סל (ETFs).
- curvo.eu - מערכת לבדיקת ביצועי עבר של קרנות אירופאיות.
- ofdollarsanddata.com - כתיבה על השקעות מבוססת נתונים סטטיסטיים.
- awealthofcommonsense.com - סקירות ורשימות על היסטוריית השווקים הפיננסיים.
- theirrelevantinvestor.com - כתיבה וניתוח של פסיכולוגיית משקיעים.
- visualcapitalist.com - הסבר על הכלכלה העולמית באמצעות אינפוגרפיקות ותרשימים.
- ourfiniteworld - בלוג כלכלי ואנליטי.

*אין באמור המלצה לפעולה או יעוץ פיננסי

הדסק הכלכלי – https://t.me/MarketDeskIL

---

## למה להחזיק אג"ח
*נערך: Sep 27*

הדיסוננס הפסיכולוגי שאתה חווה מובן לחלוטין. לראות נכס שאמור לשמש כ"חוף המבטחים" של התיק מייצר הפסד הוני, זה מתסכל. משבר האג"ח ההיסטורי של 2022-2023, בו הריביות טסו מאפס ל-5% בקצב חסר תקדים, ריסק את מחירי איגרות החוב והפר את ההבטחה הקלאסית ש"אג"ח תמיד עולה כשהמניות יורדות".

עם זאת, ארכיטקטורת המבצר אינה מבוססת על תקוות או על סנטימנט, אלא על תפקידים מתמטיים מוגדרים. BND (Vanguard Total Bond Market) מהווה עוגן בתוך שכבת הליבה (Core) ומוחזקת שם משלוש סיבות הנדסיות שאין להן תחליף:

**1. מנוע תזרים המזומנים של התיק (Cash Flow)**

בזמן שמחיר התעודה (NAV) חווה הפסד הוני בעקבות עליית הריבית, התשואה הפנימית שלה זינקה בהתאמה. BND מחלקת דיבידנד חודשי קבוע המשמש כמנוע תזרים, עם תשואת דיבידנד (SEC Yield) עדכנית הנעה סביב 4.25% עד 4.61% בשנה. התזרים הזה הוא הדלק שמייצר לנו מזומן חדש בתוך התיק מדי חודש. המזומן הזה נאגר לרזרבה ומאפשר לנו לנצל הזדמנויות ב-Ambush Radar (כמו הקניות האחרונות של FDX ו-CAT) גם בתקופות שבהן אינך מפקיד הון חיצוני לחשבון.

**2. גידור למיתון עמוק (Deflationary Ballast)**

בדו"ח המודיעין האחרון שהבאת, האסטרטג טורסטן סלוק ציין ש"משקיעים כבר לא יכולים להסתמך על אג"ח כגידור לסיכון במניות". אזהרה זו מדויקת לסביבת המאקרו הנוכחית, המאופיינת באינפלציה דביקה המאלצת את המניות והאג"ח לרדת יחד. אך המבצר נבנה לשרוד עשרות שנים וכל מחזור כלכלי אפשרי. אם הכלכלה תיכנס למיתון עמוק ואמיתי (דפלציה) ומדד ה-S&P 500 יתרסק ב-40%, הבנק המרכזי יחתוך ריביות באגרסיביות. בתרחיש כזה, מחירי האג"ח ב-BND יזנקו ויהוו רצפת בטון לתיק. יותר מכך, הזינוק הזה יאפשר לנו למכור חלק מ-BND ברווח כדי לקנות מניות VOO במחירי רצפה (Rebalancing).

**3. המתמטיקה של התאוששות אג"ח (Duration Recovery)**

הפסד באג"ח אינו זהה להפסד במניה של חברה קורסת. כשמחיר BND יורד בעקבות עליית ריבית, איגרות החוב הישנות שבתוך התעודה מבשילות ומוחלפות אוטומטית באיגרות חוב חדשות שמחלקות קופונים גבוהים יותר. משך החיים הממוצע של איגרות החוב ב-BND הוא כ-6.5 שנים. המשמעות המתמטית היא שההפסד הצף שאתה רואה כעת יקוזז במלואו על ידי תשלומי הריבית הגבוהים יותר שתקבל לאורך מחזור החיים של התעודה, גם אם הריבית במשק תישאר קפואה ברמתה הנוכחית.

**סיכום אופרטיבי (Plan & Act):**

ההפסד הצף ב-BND הוא בגדר "פרמיית ביטוח" שאנו משלמים כדי להבטיח ששכבת הליבה תייצר נזילות שוטפת ותשרוד אירועי קיצון (Black Swans).

בניגוד לשכבת הלוויינים, שבה אנו קוטעים הפסדים באכזריות באמצעות סטופ-לוס של 12% (כמו שראינו ב-ITA), BND שייכת לשכבת הליבה. חוקת המבצר מחריגה את נכסי הליבה מכל פקודת סטופ טכנית.

הסטטוס הוא Hold מוחלט. אין למכור אותה, ואין לשנות את תפקידה. תן לה להמשיך להפקיד לך את השכירות החודשית לחשבון, והתעלם מתנודות המחיר שלה.

---

## מסרים מג'ון בוגל
*נערך: Feb 21*

המסר ברור: בטווח הארוך, תשואות על מניות תלויות באופן כמעט בלעדי בתשואה שהתאגידים הניבו מהפעילות הכלכלית שלהם. לדעותיהם של המשקיעים, שמשתקפות בתשואות הספקולטיביות, יש מעט מאוד השפעה. הכלכלה היא זו ששולטת בתשואות ארוכות הטווח על מניות; השפעתם של הרגשות, החשובה כל כך בטווח הקצר, מתפוגגת בטווח הארוך.

---

## מפתח שליפה לתיק
*נערך: Feb 20*

מפתח שליפה לתיק שלך

זה סט "פקודות" קצרות שאתה שולח לי, ואני מחזיר תשובה אחידה וברורה (כולל טבלאות/אחוזים/התראות).

**1) SNAPSHOT**

תכתוב:
`SNAPSHOT | date=YYYY-MM-DD | account₪= | cash₪= | cash$= | portfolio$= | buyingPower$=`

תקבל: מצב מזומן, חלוקת ליבה/אג״ח/סקטורים/מניות, ושינויים מהסנאפשוט הקודם.

**2) POSITION**

תכתוב:
`POSITION | Ticker=OKTA`

תקבל: כמות, שווי פוזיציה, אחוז מהתיק, מחיר ממוצע מול מחיר נוכחי, רווח/הפסד, והתראת % מומלצת.

**3) SECTOR EXPOSURE**

תכתוב:
`SECTOR | show=all`
או
`SECTOR | name=Financials`

תקבל: חשיפה לפי סקטורים (כולל האם חורגים מהתקרות שקבענו: סקטורי ETF 7%, מניות בודדות 7%, ביטחון/תעופה 12%, וכו').

**4) ALERTS RESET**

תכתוב:
`ALERTS | reset=all`

תקבל: רשימת התראות מלאה לפי הקונבנציה שלך (מדדים/אג״ח/סקטורים/מניות) בפורמט שאפשר להעתיק ל-IBI:
סוג התראה: % · כיוון: גם וגם · סף: לפי הכללים שלך

**5) OPPORTUNITY CHECK**

תכתוב:
`OPPORTUNITY | Ticker=FROG | move=-7% | price=$__ | cash$=__ | cash₪=__`

תקבל: "רעש/בדיקה/הזדמנות" + האם להשתמש במזומן וכמה, בלי לשבור את כלל כרית המזומן.

**6) MONTHLY NO-NOISE**

תכתוב (5 שורות):
```
MONTHLY | date=YYYY-MM-DD
account₪= ; cash₪= ; cash$= ; portfolio$=
deposited₪=10000 (yes/no)
tradesThisMonth=...
constraints= noNewStocks? yes/no ; keepCashMin=5%
```

תקבל: הוראות איזון חודשיות מדויקות (כמה לקנות/למכור מכל נייר).

**איך להשתמש בזה בפועל (הכי יעיל)**

כל יום? לא.

שגרה: פעם בחודש → MONTHLY NO-NOISE

באמצע חודש: רק אם קפצה התראה ב-IBI → OPPORTUNITY CHECK או POSITION
