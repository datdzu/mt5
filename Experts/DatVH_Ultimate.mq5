//+------------------------------------------------------------------+
//|                                              DatVH_Ultimate.mq5  |
//|                        Copyright 2025, DatVH                     |
//|                                     https://www.metaquotes.net   |
//+------------------------------------------------------------------+
#property copyright "DatVH"
#property link      "https://www.metaquotes.net"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input string InpBotToken = "7952348323:AAHXJXRU4C9rwxm3u3G0F_smatVayq0qKlM";
input string InpChatId   = "-1003150216417";
input string InpScreenshotFolder = "Screenshots";
input int    InpScreenshotWidth  = 1280;
input int    InpScreenshotHeight = 720;

input int    InpEmaFast = 24;
input int    InpEmaSlow = 72;
input int    InpZigZagDepth = 12;
input int    InpZigZagDeviation = 5;
input int    InpZigZagBackstep = 3;

input bool   InpEnableLong = true;
input bool   InpEnableShort = true;
input bool   InpEnableDcaLong = true;
input bool   InpEnableDcaShort = true;

input double InpRiskInitialPercent = 1.0;
input double InpRiskDcaPercent = 0.5;
input double InpReferenceBalance = 0.0; // 0 = use current balance

input int    InpMaxDcaPerSide = 3;
input double InpMinDistancePips = 30.0;

input ulong  InpMagicInitial = 2509001;
input ulong  InpMagicDca     = 2509002;

input bool   InpShowZigZag = true;

CTrade trade;
int emaFastHandle = INVALID_HANDLE;
int emaSlowHandle = INVALID_HANDLE;
int zigzagHandle = INVALID_HANDLE;

string lastTrendLabel = "";
MqlRates rates[];

ulong lastTrailingLowTime = 0;
ulong lastTrailingHighTime = 0;

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
int GetPipMultiplier()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return 10;
   return 1;
}

double PipsToPrice(double pips)
{
   return pips * _Point * GetPipMultiplier();
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volume < minLot)
      return 0.0;
   volume = MathMin(volume, maxLot);
   volume = MathFloor(volume / step) * step;
   return NormalizeDouble(volume, 2);
}

double CalcRiskVolume(double slDistancePrice, double riskPercent)
{
   if(slDistancePrice <= 0.0)
      return 0.0;

   double balance = InpReferenceBalance > 0.0 ? InpReferenceBalance : AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * riskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   double moneyPerLot = slDistancePrice / tickSize * tickValue;
   if(moneyPerLot <= 0.0)
      return 0.0;

   double volume = riskAmount / moneyPerLot;
   return NormalizeVolume(volume);
}

bool HasPosition(ENUM_POSITION_TYPE type, ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByIndex(i))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      return true;
   }
   return false;
}

int CountPositions(ENUM_POSITION_TYPE type, ulong magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByIndex(i))
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)magic)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      count++;
   }
   return count;
}

double LastEntryPrice(ENUM_POSITION_TYPE type)
{
   double lastPrice = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByIndex(i))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(lastPrice == 0.0)
         lastPrice = openPrice;
      else
      {
         if(type == POSITION_TYPE_BUY)
            lastPrice = MathMin(lastPrice, openPrice);
         else
            lastPrice = MathMax(lastPrice, openPrice);
      }
   }
   return lastPrice;
}

bool CheckMinDistance(ENUM_POSITION_TYPE type, double entryPrice)
{
   if(InpMinDistancePips <= 0.0)
      return true;
   double lastPrice = LastEntryPrice(type);
   if(lastPrice == 0.0)
      return true;
   double distance = MathAbs(entryPrice - lastPrice);
   return distance >= PipsToPrice(InpMinDistancePips);
}

//+------------------------------------------------------------------+
//| ZigZag helpers                                                   |
//+------------------------------------------------------------------+
bool GetRecentZigZagPoints(double &lastHigh, ulong &lastHighTime, double &prevHigh, ulong &prevHighTime,
                           double &lastLow, ulong &lastLowTime, double &prevLow, ulong &prevLowTime)
{
   lastHigh = prevHigh = lastLow = prevLow = 0.0;
   lastHighTime = prevHighTime = lastLowTime = prevLowTime = 0;

   if(zigzagHandle == INVALID_HANDLE)
      return false;

   datetime timeBuffer[];
   double highBuffer[];
   double lowBuffer[];
   if(CopyTime(_Symbol, _Period, 0, 300, timeBuffer) <= 0)
      return false;
   if(CopyBuffer(zigzagHandle, 1, 0, 300, highBuffer) <= 0)
      return false;
   if(CopyBuffer(zigzagHandle, 2, 0, 300, lowBuffer) <= 0)
      return false;

   ArraySetAsSeries(timeBuffer, true);
   ArraySetAsSeries(highBuffer, true);
   ArraySetAsSeries(lowBuffer, true);

   for(int i = 1; i < ArraySize(highBuffer); i++)
   {
      if(highBuffer[i] != 0.0)
      {
         if(lastHigh == 0.0)
         {
            lastHigh = highBuffer[i];
            lastHighTime = (ulong)timeBuffer[i];
         }
         else if(prevHigh == 0.0)
         {
            prevHigh = highBuffer[i];
            prevHighTime = (ulong)timeBuffer[i];
            break;
         }
      }
   }

   for(int i = 1; i < ArraySize(lowBuffer); i++)
   {
      if(lowBuffer[i] != 0.0)
      {
         if(lastLow == 0.0)
         {
            lastLow = lowBuffer[i];
            lastLowTime = (ulong)timeBuffer[i];
         }
         else if(prevLow == 0.0)
         {
            prevLow = lowBuffer[i];
            prevLowTime = (ulong)timeBuffer[i];
            break;
         }
      }
   }

   return lastHigh > 0.0 || lastLow > 0.0;
}

bool GetInitialStopForShort(double &slPrice)
{
   double lastHigh, prevHigh, lastLow, prevLow;
   ulong lastHighTime, prevHighTime, lastLowTime, prevLowTime;
   if(!GetRecentZigZagPoints(lastHigh, lastHighTime, prevHigh, prevHighTime, lastLow, lastLowTime, prevLow, prevLowTime))
      return false;
   if(lastHigh == 0.0)
      return false;
   double emaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   if(lastHigh <= emaFast)
      return false;
   slPrice = lastHigh;
   return true;
}

bool GetInitialStopForLong(double &slPrice)
{
   double lastHigh, prevHigh, lastLow, prevLow;
   ulong lastHighTime, prevHighTime, lastLowTime, prevLowTime;
   if(!GetRecentZigZagPoints(lastHigh, lastHighTime, prevHigh, prevHighTime, lastLow, lastLowTime, prevLow, prevLowTime))
      return false;
   if(lastLow == 0.0)
      return false;
   double emaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   if(lastLow >= emaFast)
      return false;
   slPrice = lastLow;
   return true;
}

bool GetDcaStopForLong(double &slPrice)
{
   double lastHigh, prevHigh, lastLow, prevLow;
   ulong lastHighTime, prevHighTime, lastLowTime, prevLowTime;
   if(!GetRecentZigZagPoints(lastHigh, lastHighTime, prevHigh, prevHighTime, lastLow, lastLowTime, prevLow, prevLowTime))
      return false;
   if(lastLow == 0.0 || prevLow == 0.0)
      return false;
   if(prevLow >= lastLow)
      return false;
   slPrice = prevLow;
   return true;
}

bool GetDcaStopForShort(double &slPrice)
{
   double lastHigh, prevHigh, lastLow, prevLow;
   ulong lastHighTime, prevHighTime, lastLowTime, prevLowTime;
   if(!GetRecentZigZagPoints(lastHigh, lastHighTime, prevHigh, prevHighTime, lastLow, lastLowTime, prevLow, prevLowTime))
      return false;
   if(lastHigh == 0.0 || prevHigh == 0.0)
      return false;
   if(prevHigh <= lastHigh)
      return false;
   slPrice = prevHigh;
   return true;
}

//+------------------------------------------------------------------+
//| Telegram                                                         |
//+------------------------------------------------------------------+
bool SaveScreenshot(string &fileName)
{
   datetime now = TimeCurrent();
   string timeTag = TimeToString(now, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   timeTag = StringReplace(timeTag, ":", "-");
   timeTag = StringReplace(timeTag, " ", "_");

   FolderCreate(InpScreenshotFolder);
   fileName = InpScreenshotFolder + "/" + _Symbol + "_" + timeTag + ".png";
   string fullPath = fileName;

   bool ok = ChartScreenShot(0, fullPath, InpScreenshotWidth, InpScreenshotHeight, ALIGN_RIGHT);
   return ok;
}

bool SendTelegramPhoto(const string message)
{
   string fileName;
   if(!SaveScreenshot(fileName))
      return false;

   int fileHandle = FileOpen(fileName, FILE_READ|FILE_BIN);
   if(fileHandle == INVALID_HANDLE)
      return false;
   int fileSize = (int)FileSize(fileHandle);
   uchar fileData[];
   ArrayResize(fileData, fileSize);
   FileReadArray(fileHandle, fileData, 0, fileSize);
   FileClose(fileHandle);

   string boundary = "------------------------" + IntegerToString((int)GetTickCount());

   string header = "--" + boundary + "\r\n";
   header += "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n" + InpChatId + "\r\n";
   header += "--" + boundary + "\r\n";
   header += "Content-Disposition: form-data; name=\"caption\"\r\n\r\n" + message + "\r\n";
   header += "--" + boundary + "\r\n";
   header += "Content-Disposition: form-data; name=\"photo\"; filename=\"chart.png\"\r\n";
   header += "Content-Type: image/png\r\n\r\n";

   string footer = "\r\n--" + boundary + "--\r\n";

   uchar data[];
   int headerLen = StringToCharArray(header, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   int footerLen = StringToCharArray(footer, data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   if(headerLen < 0)
      headerLen = 0;
   if(footerLen < 0)
      footerLen = 0;

   ArrayResize(data, headerLen + fileSize + footerLen);
   StringToCharArray(header, data, 0, WHOLE_ARRAY, CP_UTF8);
   for(int i = 0; i < fileSize; i++)
      data[headerLen + i] = fileData[i];

   StringToCharArray(footer, data, headerLen + fileSize, WHOLE_ARRAY, CP_UTF8);

   string url = "https://api.telegram.org/bot" + InpBotToken + "/sendPhoto";
   string headers = "Content-Type: multipart/form-data; boundary=" + boundary;
   char result[];
   int res = WebRequest("POST", url, headers, 5000, data, result, headers);
   return (res == 200);
}

void NotifyEvent(const string message)
{
   SendTelegramPhoto(message);
}

//+------------------------------------------------------------------+
//| Signals                                                          |
//+------------------------------------------------------------------+
bool IsUptrend()
{
   double emaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   return emaFast > emaSlow;
}

bool IsDowntrend()
{
   double emaFast = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   return emaFast < emaSlow;
}

bool InitialShortSignal()
{
   double emaFast1 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow1 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaFast2 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 2);
   double emaSlow2 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 2);

   double close1 = rates[1].close;
   double close2 = rates[2].close;

   bool breakDown = close2 > emaFast2 && close2 > emaSlow2 && close1 < emaFast1 && close1 < emaSlow1;
   return breakDown;
}

bool InitialLongSignal()
{
   double emaFast1 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow1 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaFast2 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 2);
   double emaSlow2 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 2);

   double close1 = rates[1].close;
   double close2 = rates[2].close;

   bool breakUp = close2 < emaFast2 && close2 < emaSlow2 && close1 > emaFast1 && close1 > emaSlow1;
   return breakUp;
}

bool DcaLongSignal()
{
   double emaFast1 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow1 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaFast2 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 2);
   double emaSlow2 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 2);

   double close1 = rates[1].close;
   double close2 = rates[2].close;

   bool pulledBack = close2 < emaFast2 && close2 > emaSlow2;
   bool rebound = close1 > emaFast1;
   return pulledBack && rebound;
}

bool DcaShortSignal()
{
   double emaFast1 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow1 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaFast2 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 2);
   double emaSlow2 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 2);

   double close1 = rates[1].close;
   double close2 = rates[2].close;

   bool pulledBack = close2 > emaFast2 && close2 < emaSlow2;
   bool rebound = close1 < emaFast1;
   return pulledBack && rebound;
}

void HandleEmaCross()
{
   double emaFast1 = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow1 = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   string trend = emaFast1 > emaSlow1 ? "Uptrend" : (emaFast1 < emaSlow1 ? "Downtrend" : "Sideway");
   if(trend != lastTrendLabel && trend != "Sideway")
   {
      string message = _Symbol + " | " + trend;
      NotifyEvent(message);
      lastTrendLabel = trend;
   }
}

//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
void PlaceInitialOrder(ENUM_POSITION_TYPE type)
{
   double entry = SymbolInfoDouble(_Symbol, type == POSITION_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
   if(!CheckMinDistance(type, entry))
      return;

   double slPrice = 0.0;
   bool slOk = (type == POSITION_TYPE_BUY) ? GetInitialStopForLong(slPrice) : GetInitialStopForShort(slPrice);
   if(!slOk)
      return;

   double slDistance = MathAbs(entry - slPrice);
   double volume = CalcRiskVolume(slDistance, InpRiskInitialPercent);
   if(volume <= 0.0)
   {
      string message = _Symbol + " | " + (type == POSITION_TYPE_BUY ? "Long" : "Short") + " Signal | No Valid Volume";
      NotifyEvent(message);
      return;
   }

   trade.SetExpertMagicNumber(InpMagicInitial);
   bool result = false;
   if(type == POSITION_TYPE_BUY)
      result = trade.Buy(volume, _Symbol, entry, slPrice, 0.0, "Initial Long");
   else
      result = trade.Sell(volume, _Symbol, entry, slPrice, 0.0, "Initial Short");

   if(result)
   {
      double riskUsd = (InpReferenceBalance > 0.0 ? InpReferenceBalance : AccountInfoDouble(ACCOUNT_BALANCE)) * InpRiskInitialPercent / 100.0;
      string message = _Symbol + " | " + (type == POSITION_TYPE_BUY ? "Long Signal" : "Short Signal") + " | Entry " + DoubleToString(entry, _Digits) + " | SL " + DoubleToString(slPrice, _Digits) + " | Risk USD " + DoubleToString(riskUsd, 2) + " (" + DoubleToString(InpRiskInitialPercent, 2) + "%)";
      NotifyEvent(message);
   }
}

void PlaceDcaOrder(ENUM_POSITION_TYPE type)
{
   if(CountPositions(type, InpMagicDca) >= InpMaxDcaPerSide)
      return;

   double entry = SymbolInfoDouble(_Symbol, type == POSITION_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
   if(!CheckMinDistance(type, entry))
      return;

   double slPrice = 0.0;
   bool slOk = (type == POSITION_TYPE_BUY) ? GetDcaStopForLong(slPrice) : GetDcaStopForShort(slPrice);
   if(!slOk)
      return;

   double slDistance = MathAbs(entry - slPrice);
   double volume = CalcRiskVolume(slDistance, InpRiskDcaPercent);
   if(volume <= 0.0)
   {
      string message = _Symbol + " | " + (type == POSITION_TYPE_BUY ? "Long Signal DCA" : "Short Signal DCA") + " | No Valid Volume";
      NotifyEvent(message);
      return;
   }

   trade.SetExpertMagicNumber(InpMagicDca);
   bool result = false;
   if(type == POSITION_TYPE_BUY)
      result = trade.Buy(volume, _Symbol, entry, slPrice, 0.0, "DCA Long");
   else
      result = trade.Sell(volume, _Symbol, entry, slPrice, 0.0, "DCA Short");

   if(result)
   {
      double riskUsd = (InpReferenceBalance > 0.0 ? InpReferenceBalance : AccountInfoDouble(ACCOUNT_BALANCE)) * InpRiskDcaPercent / 100.0;
      string message = _Symbol + " | " + (type == POSITION_TYPE_BUY ? "Long Signal DCA" : "Short Signal DCA") + " | Entry " + DoubleToString(entry, _Digits) + " | SL " + DoubleToString(slPrice, _Digits) + " | Risk USD " + DoubleToString(riskUsd, 2) + " (" + DoubleToString(InpRiskDcaPercent, 2) + "%)";
      NotifyEvent(message);
   }
}

void UpdateTrailingStops()
{
   double lastHigh, prevHigh, lastLow, prevLow;
   ulong lastHighTime, prevHighTime, lastLowTime, prevLowTime;
   if(!GetRecentZigZagPoints(lastHigh, lastHighTime, prevHigh, prevHighTime, lastLow, lastLowTime, prevLow, prevLowTime))
      return;

   if(lastLowTime > lastTrailingLowTime && prevLow > 0.0 && prevLow < lastLow)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!PositionSelectByIndex(i))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
            continue;
         double currentSl = PositionGetDouble(POSITION_SL);
         if(currentSl == 0.0 || prevLow > currentSl)
         {
            trade.SetExpertMagicNumber((ulong)PositionGetInteger(POSITION_MAGIC));
            trade.PositionModify(PositionGetString(POSITION_SYMBOL), prevLow, PositionGetDouble(POSITION_TP));
            string message = _Symbol + " | Trailing SL to price " + DoubleToString(prevLow, _Digits);
            NotifyEvent(message);
         }
      }
      lastTrailingLowTime = lastLowTime;
   }

   if(lastHighTime > lastTrailingHighTime && prevHigh > 0.0 && prevHigh > lastHigh)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!PositionSelectByIndex(i))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;
         double currentSl = PositionGetDouble(POSITION_SL);
         if(currentSl == 0.0 || prevHigh < currentSl)
         {
            trade.SetExpertMagicNumber((ulong)PositionGetInteger(POSITION_MAGIC));
            trade.PositionModify(PositionGetString(POSITION_SYMBOL), prevHigh, PositionGetDouble(POSITION_TP));
            string message = _Symbol + " | Trailing SL to price " + DoubleToString(prevHigh, _Digits);
            NotifyEvent(message);
         }
      }
      lastTrailingHighTime = lastHighTime;
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(CopyRates(_Symbol, _Period, 0, 5, rates) <= 0)
      return;
   ArraySetAsSeries(rates, true);

   HandleEmaCross();
   UpdateTrailingStops();

   bool uptrend = IsUptrend();
   bool downtrend = IsDowntrend();

   bool hasInitialBuy = HasPosition(POSITION_TYPE_BUY, InpMagicInitial);
   bool hasInitialSell = HasPosition(POSITION_TYPE_SELL, InpMagicInitial);

   if(uptrend && InpEnableShort && !hasInitialSell)
   {
      if(InitialShortSignal())
         PlaceInitialOrder(POSITION_TYPE_SELL);
   }

   if(downtrend && InpEnableLong && !hasInitialBuy)
   {
      if(InitialLongSignal())
         PlaceInitialOrder(POSITION_TYPE_BUY);
   }

   bool hasInitial = hasInitialBuy || hasInitialSell;
   if(!hasInitial)
      return;

   if(uptrend && InpEnableDcaLong)
   {
      if(DcaLongSignal())
         PlaceDcaOrder(POSITION_TYPE_BUY);
   }

   if(downtrend && InpEnableDcaShort)
   {
      if(DcaShortSignal())
         PlaceDcaOrder(POSITION_TYPE_SELL);
   }

   if(hasInitialBuy && InpEnableDcaShort && DcaShortSignal())
      PlaceDcaOrder(POSITION_TYPE_SELL);

   if(hasInitialSell && InpEnableDcaLong && DcaLongSignal())
      PlaceDcaOrder(POSITION_TYPE_BUY);
}

//+------------------------------------------------------------------+
//| OnInit / OnDeinit                                                |
//+------------------------------------------------------------------+
int OnInit()
{
   emaFastHandle = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   zigzagHandle = iCustom(_Symbol, _Period, "ZigZag", InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);

   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE || zigzagHandle == INVALID_HANDLE)
      return INIT_FAILED;

   if(InpShowZigZag)
      ChartIndicatorAdd(0, 0, zigzagHandle);

   string message = "Bot kết nối thành công " + _Symbol + " | " + EnumToString(_Period);
   NotifyEvent(message);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(emaFastHandle);
   if(emaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(emaSlowHandle);
   if(zigzagHandle != INVALID_HANDLE)
      IndicatorRelease(zigzagHandle);
}

//+------------------------------------------------------------------+
//| Position closure notification                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.entry != DEAL_ENTRY_OUT)
      return;

   if(trans.symbol != _Symbol)
      return;

   double pnl = trans.profit + trans.commission + trans.swap;
   string reason = trans.deal_reason == DEAL_REASON_SL ? "SL" : (trans.deal_reason == DEAL_REASON_TP ? "TP" : "Close");
   string message = _Symbol + " Close Position | " + reason + " price " + DoubleToString(trans.price, _Digits) + " | PnL USD " + DoubleToString(pnl, 2);
   NotifyEvent(message);
}
