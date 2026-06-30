using System.Collections.Concurrent;
using System.Globalization;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.Win32;
using System.Diagnostics;

namespace BtcCollector;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Global\\BTCRealtimeCollector_XiaoZhu_CSharp_v2", out var created);
        if (!created) return;
        Application.Run(new MainForm(args));
    }
}

public sealed class Snapshot
{
    public string SchemaVersion { get; set; } = Collector.SchemaVersion;
    public string EventType { get; set; } = "init";
    public string Exchange { get; set; } = "";
    public string Symbol { get; set; } = "";
    public string Price { get; set; } = "--";
    public string Funding { get; set; } = "--";
    public string Equity { get; set; } = "--";
    public string Available { get; set; } = "--";
    public string Position { get; set; } = "--";
    public string Entry { get; set; } = "--";
    public string Mark { get; set; } = "--";
    public string Upnl { get; set; } = "--";
    public string Liq { get; set; } = "--";
    public string OpenOrders { get; set; } = "--";
    public string Status { get; set; } = "启动中";
    public string LastSuccess { get; set; } = "";
    public int ConsecutiveFailures { get; set; }
}

public sealed class Health
{
    public string LastSuccess { get; set; } = "";
    public string LastError { get; set; } = "";
    public int ConsecutiveFailures { get; set; }
    public string UpdatedAt { get; set; } = "";
}

public sealed class Collector
{
    public const string SchemaVersion = "2.3.0";
    public readonly string BaseDir;
    public string OutputDir
    {
        get
        {
            var cfg = LoadConfig();
            var v = Cfg(cfg, "DATA_OUTPUT_DIR", "");
            if (string.IsNullOrWhiteSpace(v)) return BaseDir;
            return Path.IsPathRooted(v) ? v : Path.Combine(BaseDir, v);
        }
    }
    public string DataDir => Path.Combine(OutputDir, "data");
    public string LogDir => Path.Combine(OutputDir, "logs");
    public string DbPath => Path.Combine(DataDir, "btc_collector.sqlite3");
    readonly string _configPath;
    readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(6) };
    readonly ConcurrentDictionary<string, Snapshot> _snaps = new();
    readonly ConcurrentDictionary<string, Health> _health = new();
    readonly object _persistLock = new();
    CancellationTokenSource? _cts;
    public event Action<IReadOnlyList<Snapshot>, string>? Updated;
    public event Action<string>? LogLine;

    public Collector()
    {
        BaseDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        _configPath = Path.Combine(BaseDir, "config.env");
        EnsureDirs();
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("BTC-Realtime-Monitor/2.0");
    }

    void EnsureDirs()
    {
        Directory.CreateDirectory(DataDir);
        Directory.CreateDirectory(LogDir);
    }

    public string ConfigPath => _configPath;

    public Dictionary<string,string> LoadConfig()
    {
        var d = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(_configPath)) return d;
        foreach (var raw in File.ReadAllLines(_configPath, Encoding.UTF8))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#') || !line.Contains('=')) continue;
            var idx = line.IndexOf('=');
            d[line[..idx].Trim()] = line[(idx+1)..].Trim();
        }
        return d;
    }
    public void SaveConfig(Dictionary<string,string> cfg)
    {
        var order = new[] { "BINANCE_ENABLED", "BINANCE_API_KEY", "BINANCE_API_SECRET", "BINANCE_SYMBOL", "OKX_ENABLED", "OKX_API_KEY", "OKX_API_SECRET", "OKX_API_PASSPHRASE", "OKX_INST_ID", "PRICE_REFRESH_SECONDS", "ACCOUNT_REFRESH_SECONDS", "FUNDING_REFRESH_SECONDS", "DATA_OUTPUT_DIR", "RETENTION_DAYS" };
        var sb = new StringBuilder();
        sb.AppendLine("# BTC实时通信系统配置");
        sb.AppendLine("# API Key 只需要读取权限，不要开启交易/提现");
        foreach (var k in order)
        {
            if (k is "OKX_ENABLED") sb.AppendLine();
            if (k is "PRICE_REFRESH_SECONDS") { sb.AppendLine(); sb.AppendLine("# 刷新频率：WebSocket实时更新内存；这里控制界面/落库/REST轮询频率"); }
            if (k is "DATA_OUTPUT_DIR") { sb.AppendLine(); sb.AppendLine("# 输出目录，留空表示程序所在目录；会在该目录下生成 data/ 和 logs/"); }
            if (k is "RETENTION_DAYS") { sb.AppendLine(); sb.AppendLine("# 自动清理历史数据，范围7-30天"); }
            sb.AppendLine($"{k}={cfg.GetValueOrDefault(k, "")}");
        }
        File.WriteAllText(_configPath, sb.ToString(), Encoding.UTF8);
    }

    static string Cfg(Dictionary<string,string> cfg, string k, string def="") => cfg.TryGetValue(k, out var v) && !string.IsNullOrWhiteSpace(v) ? v : def;
    static int CfgInt(Dictionary<string,string> cfg, string k, int def, int min) => Math.Max(min, int.TryParse(Cfg(cfg,k), out var v) ? v : def);

    public void Start()
    {
        CleanupWorkspaceTrash();
        InitDb();
        EnsureInitialState();
        _cts = new CancellationTokenSource();
        _ = Task.Run(() => BinanceWsLoop(_cts.Token));
        _ = Task.Run(() => OkxWsLoop(_cts.Token));
        _ = Task.Run(() => PricePublishLoop(_cts.Token));
        _ = Task.Run(() => AccountLoop(_cts.Token));
        _ = Task.Run(() => FundingLoop(_cts.Token));
        _ = Task.Run(() => CleanupLoop(_cts.Token));
        Publish("start");
        Log("C# v2.3 启动：WebSocket价格 + REST账户 + SQLite + 自动清理");
    }

    public void Stop() => _cts?.Cancel();

    void EnsureInitialState()
    {
        var cfg = LoadConfig();
        _snaps["Binance U本位"] = new Snapshot { Exchange="Binance U本位", Symbol=Cfg(cfg,"BINANCE_SYMBOL","BTCUSDT") };
        _snaps["OKX 币本位"] = new Snapshot { Exchange="OKX 币本位", Symbol=Cfg(cfg,"OKX_INST_ID","BTC-USD-SWAP") };
    }

    void InitDb()
    {
        EnsureDirs();
        using var cn = new SqliteConnection($"Data Source={DbPath}");
        cn.Open();
        using var cmd = cn.CreateCommand();
        cmd.CommandText = @"
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS snapshots(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 schema_version TEXT NOT NULL,
 ts TEXT NOT NULL,
 event_type TEXT NOT NULL,
 exchange TEXT NOT NULL,
 symbol TEXT,
 price TEXT,
 funding TEXT,
 equity TEXT,
 available TEXT,
 position TEXT,
 entry TEXT,
 mark TEXT,
 upnl TEXT,
 liq TEXT,
 open_orders TEXT,
 status TEXT,
 last_success TEXT,
 consecutive_failures INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_snapshots_ts_exchange ON snapshots(ts,exchange);
CREATE TABLE IF NOT EXISTS heartbeat(
 exchange TEXT PRIMARY KEY,
 schema_version TEXT NOT NULL,
 last_success TEXT,
 last_error TEXT,
 consecutive_failures INTEGER DEFAULT 0,
 updated_at TEXT NOT NULL
);";
        cmd.ExecuteNonQuery();
    }

    void Log(string s)
    {
        EnsureDirs();
        var line = $"[{Now()}] {s}";
        try { File.AppendAllText(Path.Combine(LogDir,"collector.log"), line+Environment.NewLine, Encoding.UTF8); } catch {}
        LogLine?.Invoke(line);
    }
    static string Now() => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");

    async Task BinanceWsLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var cfg = LoadConfig();
            if (Cfg(cfg,"BINANCE_ENABLED","true").Equals("false", StringComparison.OrdinalIgnoreCase)) { await Task.Delay(5000,ct); continue; }
            var symbol = Cfg(cfg,"BINANCE_SYMBOL","BTCUSDT").ToLowerInvariant();
            var url = new Uri($"wss://fstream.binance.com/ws/{symbol}@markPrice@1s");
            try
            {
                using var ws = new ClientWebSocket();
                await ws.ConnectAsync(url, ct);
                Log("Binance WebSocket 已连接");
                await ReceiveLoop(ws, ct, msg =>
                {
                    using var doc = JsonDocument.Parse(msg);
                    var root = doc.RootElement;
                    var s = _snaps.GetOrAdd("Binance U本位", _ => new Snapshot{Exchange="Binance U本位", Symbol=symbol.ToUpperInvariant()});
                    s.Symbol = Cfg(cfg,"BINANCE_SYMBOL","BTCUSDT");
                    var markValue = "";
                    if (root.TryGetProperty("p", out var p)) markValue = p.GetString() ?? "";
                    if (string.IsNullOrWhiteSpace(markValue) && root.TryGetProperty("i", out var i)) markValue = i.GetString() ?? "";
                    if (!string.IsNullOrWhiteSpace(markValue)) { s.Price = markValue; s.Mark = markValue; }
                    if (root.TryGetProperty("r", out var r) && decimal.TryParse(r.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var rate)) s.Funding = (rate*100m).ToString("0.#####", CultureInfo.InvariantCulture)+"%";
                    s.Status = "OK";
                    Touch("Binance U本位", true, "");
                });
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                Touch("Binance U本位", false, "WebSocket失败："+ex.Message);
                SetStatus("Binance U本位", "WebSocket失败："+ex.Message);
                Publish("price");
                Log("Binance WS重连："+ex.Message);
                await Task.Delay(3000, ct);
            }
        }
    }

    async Task OkxWsLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var cfg = LoadConfig();
            if (Cfg(cfg,"OKX_ENABLED","true").Equals("false", StringComparison.OrdinalIgnoreCase)) { await Task.Delay(5000,ct); continue; }
            var inst = Cfg(cfg,"OKX_INST_ID","BTC-USD-SWAP");
            try
            {
                using var ws = new ClientWebSocket();
                await ws.ConnectAsync(new Uri("wss://ws.okx.com:8443/ws/v5/public"), ct);
                var sub = $"{{\"op\":\"subscribe\",\"args\":[{{\"channel\":\"tickers\",\"instId\":\"{inst}\"}},{{\"channel\":\"funding-rate\",\"instId\":\"{inst}\"}}]}}";
                await ws.SendAsync(Encoding.UTF8.GetBytes(sub), WebSocketMessageType.Text, true, ct);
                Log("OKX WebSocket 已连接");
                await ReceiveLoop(ws, ct, msg =>
                {
                    using var doc = JsonDocument.Parse(msg);
                    var root = doc.RootElement;
                    if (!root.TryGetProperty("arg", out var arg) || !root.TryGetProperty("data", out var data) || data.GetArrayLength()==0) return;
                    var channel = arg.GetProperty("channel").GetString();
                    var row = data[0];
                    var s = _snaps.GetOrAdd("OKX 币本位", _ => new Snapshot{Exchange="OKX 币本位", Symbol=inst});
                    s.Symbol = inst;
                    if (channel == "tickers" && row.TryGetProperty("last", out var last)) s.Price = last.GetString() ?? s.Price;
                    if (channel == "funding-rate" && row.TryGetProperty("fundingRate", out var fr) && decimal.TryParse(fr.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var rate)) s.Funding = (rate*100m).ToString("0.#####", CultureInfo.InvariantCulture)+"%";
                    s.Status = "OK";
                    Touch("OKX 币本位", true, "");
                });
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                Touch("OKX 币本位", false, "WebSocket失败："+ex.Message);
                SetStatus("OKX 币本位", "WebSocket失败："+ex.Message);
                Publish("price");
                Log("OKX WS重连："+ex.Message);
                await Task.Delay(3000, ct);
            }
        }
    }

    static async Task ReceiveLoop(ClientWebSocket ws, CancellationToken ct, Action<string> onMessage)
    {
        var buf = new byte[64*1024];
        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            using var ms = new MemoryStream();
            WebSocketReceiveResult r;
            do
            {
                r = await ws.ReceiveAsync(buf, ct);
                if (r.MessageType == WebSocketMessageType.Close) return;
                ms.Write(buf,0,r.Count);
            } while (!r.EndOfMessage);
            onMessage(Encoding.UTF8.GetString(ms.ToArray()));
        }
    }

    async Task PricePublishLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var cfg = LoadConfig();
                var sec = CfgInt(cfg,"PRICE_REFRESH_SECONDS",3,1);
                Publish("price");
                await Task.Delay(TimeSpan.FromSeconds(sec), ct);
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Log("价格落库循环异常：" + ex.Message);
                await Task.Delay(3000, ct);
            }
        }
    }

    public async Task RefreshNow()
    {
        try
        {
            var cfg = LoadConfig();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await RefreshFundingRest(cfg, cts.Token);
            await RefreshAccountOnce(cfg, cts.Token);
            Publish("manual");
        }
        catch (Exception ex) { Log("手动刷新失败：" + ex.Message); }
    }

    public async Task<string> TestConnection(string exchange)
    {
        try
        {
            var cfg = LoadConfig();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            if (exchange == "Binance")
            {
                var sym = Cfg(cfg,"BINANCE_SYMBOL","BTCUSDT");
                await GetJson($"https://fapi.binance.com/fapi/v1/premiumIndex?symbol={sym}", cts.Token);
                try { await BinanceSigned("/fapi/v2/account", new(), cfg, cts.Token); return "Binance：公开行情OK，私有账户OK"; }
                catch (Exception ex) { return "Binance：公开行情OK，私有账户失败：" + ex.Message; }
            }
            else
            {
                var inst = Cfg(cfg,"OKX_INST_ID","BTC-USD-SWAP");
                await GetJson($"https://www.okx.com/api/v5/public/funding-rate?instId={inst}", cts.Token);
                try { await OkxPrivate("/api/v5/account/balance?ccy=BTC", cfg, cts.Token); return "OKX：公开行情OK，私有账户OK"; }
                catch (Exception ex) { return "OKX：公开行情OK，私有账户失败：" + ex.Message; }
            }
        }
        catch (Exception ex) { return exchange + "：连接失败：" + ex.Message; }
    }

    async Task AccountLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var cfg = LoadConfig();
            var sec = CfgInt(cfg,"ACCOUNT_REFRESH_SECONDS",10,5);
            await RefreshAccountOnce(cfg, ct);
            await Task.Delay(TimeSpan.FromSeconds(sec), ct);
        }
    }

    async Task FundingLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var cfg = LoadConfig();
            var sec = CfgInt(cfg,"FUNDING_REFRESH_SECONDS",60,30);
            await RefreshFundingRest(cfg, ct);
            await Task.Delay(TimeSpan.FromSeconds(sec), ct);
        }
    }

    async Task RefreshAccountOnce(Dictionary<string,string> cfg, CancellationToken ct)
    {
        if (!Cfg(cfg,"BINANCE_ENABLED","true").Equals("false", StringComparison.OrdinalIgnoreCase)) await RefreshBinanceAccount(cfg, ct);
        if (!Cfg(cfg,"OKX_ENABLED","true").Equals("false", StringComparison.OrdinalIgnoreCase)) await RefreshOkxAccount(cfg, ct);
        Publish("account");
    }

    async Task RefreshFundingRest(Dictionary<string,string> cfg, CancellationToken ct)
    {
        try
        {
            var bs = Cfg(cfg,"BINANCE_SYMBOL","BTCUSDT");
            var b = await GetJson($"https://fapi.binance.com/fapi/v1/premiumIndex?symbol={bs}", ct);
            var s = _snaps.GetOrAdd("Binance U本位", _ => new Snapshot{Exchange="Binance U本位", Symbol=bs});
            s.Mark = b.RootElement.GetProperty("markPrice").GetString() ?? s.Mark;
            if (s.Price == "--") s.Price = s.Mark;
            if (decimal.TryParse(b.RootElement.GetProperty("lastFundingRate").GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var br)) s.Funding=(br*100m).ToString("0.#####", CultureInfo.InvariantCulture)+"%";
            Touch("Binance U本位", true, "");
        } catch (Exception ex) { Touch("Binance U本位", false, "资金费率失败："+ex.Message); }
        try
        {
            var inst = Cfg(cfg,"OKX_INST_ID","BTC-USD-SWAP");
            var o = await GetJson($"https://www.okx.com/api/v5/public/funding-rate?instId={inst}", ct);
            var row = o.RootElement.GetProperty("data")[0];
            var s = _snaps.GetOrAdd("OKX 币本位", _ => new Snapshot{Exchange="OKX 币本位", Symbol=inst});
            if (decimal.TryParse(row.GetProperty("fundingRate").GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var or)) s.Funding=(or*100m).ToString("0.#####", CultureInfo.InvariantCulture)+"%";
            Touch("OKX 币本位", true, "");
        } catch (Exception ex) { Touch("OKX 币本位", false, "资金费率失败："+ex.Message); }
        Publish("funding");
    }

    async Task<JsonDocument> GetJson(string url, CancellationToken ct, Dictionary<string,string>? headers=null)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        if (headers != null) foreach (var kv in headers) req.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
        using var resp = await _http.SendAsync(req, ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode) throw new Exception($"HTTP {(int)resp.StatusCode}: {text}");
        return JsonDocument.Parse(text);
    }

    async Task RefreshBinanceAccount(Dictionary<string,string> cfg, CancellationToken ct)
    {
        var symbol = Cfg(cfg,"BINANCE_SYMBOL","BTCUSDT");
        var s = _snaps.GetOrAdd("Binance U本位", _ => new Snapshot{Exchange="Binance U本位", Symbol=symbol});
        try
        {
            var acct = await BinanceSigned("/fapi/v2/account", new(), cfg, ct);
            s.Equity = Prop(acct.RootElement,"totalWalletBalance");
            s.Available = Prop(acct.RootElement,"availableBalance");
            var posDoc = await BinanceSigned("/fapi/v2/positionRisk", new(){["symbol"]=symbol}, cfg, ct);
            if (posDoc.RootElement.ValueKind == JsonValueKind.Array && posDoc.RootElement.GetArrayLength()>0)
            {
                var p = posDoc.RootElement[0];
                s.Position = Prop(p,"positionAmt"); s.Entry=Prop(p,"entryPrice"); s.Mark=Prop(p,"markPrice"); if (s.Price == "--") s.Price = s.Mark; s.Upnl=Prop(p,"unRealizedProfit"); s.Liq=Prop(p,"liquidationPrice");
            }
            var orders = await BinanceSigned("/fapi/v1/openOrders", new(){["symbol"]=symbol}, cfg, ct);
            s.OpenOrders = orders.RootElement.ValueKind==JsonValueKind.Array ? orders.RootElement.GetArrayLength().ToString() : "0";
            s.Status="OK"; Touch("Binance U本位", true, "");
        }
        catch(Exception ex) { s.Status="账户接口失败："+ex.Message; Touch("Binance U本位", false, s.Status); }
    }

    async Task<JsonDocument> BinanceSigned(string path, Dictionary<string,string> pars, Dictionary<string,string> cfg, CancellationToken ct)
    {
        var key=Cfg(cfg,"BINANCE_API_KEY"); var sec=Cfg(cfg,"BINANCE_API_SECRET");
        if (string.IsNullOrWhiteSpace(key)||string.IsNullOrWhiteSpace(sec)) throw new Exception("Binance API Key/Secret 未完整配置");
        var time = await GetJson("https://fapi.binance.com/fapi/v1/time", ct);
        pars["timestamp"] = time.RootElement.GetProperty("serverTime").GetRawText(); pars["recvWindow"]="5000";
        var query = string.Join('&', pars.OrderBy(k=>k.Key).Select(k=>$"{Uri.EscapeDataString(k.Key)}={Uri.EscapeDataString(k.Value)}"));
        var sig = HmacHex(sec, query);
        return await GetJson("https://fapi.binance.com"+path+"?"+query+"&signature="+sig, ct, new(){["X-MBX-APIKEY"]=key});
    }

    async Task RefreshOkxAccount(Dictionary<string,string> cfg, CancellationToken ct)
    {
        var inst = Cfg(cfg,"OKX_INST_ID","BTC-USD-SWAP");
        var s = _snaps.GetOrAdd("OKX 币本位", _ => new Snapshot{Exchange="OKX 币本位", Symbol=inst});
        try
        {
            var bal = await OkxPrivate("/api/v5/account/balance?ccy=BTC", cfg, ct);
            foreach (var d in bal.RootElement.GetProperty("data")[0].GetProperty("details").EnumerateArray()) if (Prop(d,"ccy")=="BTC") { s.Equity=Prop(d,"eq"); s.Available=Prop(d,"availBal"); break; }
            var pos = await OkxPrivate($"/api/v5/account/positions?instType=SWAP&instId={inst}", cfg, ct);
            JsonElement? chosen = null;
            foreach (var p in pos.RootElement.GetProperty("data").EnumerateArray()) { if (decimal.TryParse(Prop(p,"pos"), NumberStyles.Any, CultureInfo.InvariantCulture, out var n) && n!=0) { chosen=p; break; } if (chosen==null) chosen=p; }
            if (chosen is JsonElement pe)
            {
                var side=Prop(pe,"posSide"); var amount=Prop(pe,"pos"); s.Position = !string.IsNullOrWhiteSpace(side)&&side!="net" ? side+" "+amount : amount;
                s.Entry=Prop(pe,"avgPx"); s.Mark=Prop(pe,"markPx"); s.Upnl=Prop(pe,"upl"); s.Liq=Prop(pe,"liqPx");
            }
            var orders = await OkxPrivate($"/api/v5/trade/orders-pending?instId={inst}", cfg, ct);
            s.OpenOrders = orders.RootElement.GetProperty("data").GetArrayLength().ToString();
            s.Status="OK"; Touch("OKX 币本位", true, "");
        }
        catch(Exception ex) { s.Status="账户接口失败："+ex.Message; Touch("OKX 币本位", false, s.Status); }
    }

    async Task<JsonDocument> OkxPrivate(string requestPath, Dictionary<string,string> cfg, CancellationToken ct)
    {
        var key=Cfg(cfg,"OKX_API_KEY"); var sec=Cfg(cfg,"OKX_API_SECRET"); var pass=Cfg(cfg,"OKX_API_PASSPHRASE");
        if (string.IsNullOrWhiteSpace(key)||string.IsNullOrWhiteSpace(sec)||string.IsNullOrWhiteSpace(pass)) throw new Exception("OKX API Key/Secret/Passphrase 未完整配置");
        var ts = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);
        var sign = HmacBase64(sec, ts+"GET"+requestPath);
        return await GetJson("https://www.okx.com"+requestPath, ct, new(){["OK-ACCESS-KEY"]=key,["OK-ACCESS-SIGN"]=sign,["OK-ACCESS-TIMESTAMP"]=ts,["OK-ACCESS-PASSPHRASE"]=pass});
    }

    static string Prop(JsonElement e, string name) => e.TryGetProperty(name, out var v) ? (v.ValueKind==JsonValueKind.String ? v.GetString()??"" : v.GetRawText()) : "";
    static string HmacHex(string secret, string msg){ using var h=new HMACSHA256(Encoding.UTF8.GetBytes(secret)); return Convert.ToHexString(h.ComputeHash(Encoding.UTF8.GetBytes(msg))).ToLowerInvariant(); }
    static string HmacBase64(string secret, string msg){ using var h=new HMACSHA256(Encoding.UTF8.GetBytes(secret)); return Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes(msg))); }

    void Touch(string exchange, bool ok, string error)
    {
        var h = _health.GetOrAdd(exchange, _ => new Health()); h.UpdatedAt=Now();
        if (ok) { h.LastSuccess=Now(); h.LastError=""; h.ConsecutiveFailures=0; }
        else { h.LastError=error; h.ConsecutiveFailures++; }
        if (_snaps.TryGetValue(exchange, out var s)) { s.LastSuccess=h.LastSuccess; s.ConsecutiveFailures=h.ConsecutiveFailures; }
    }
    void SetStatus(string exchange, string status) { if (_snaps.TryGetValue(exchange, out var s)) s.Status=status; }

    void Publish(string eventType)
    {
        var list = _snaps.Values.OrderBy(s=>s.Exchange).ToList();
        foreach (var s in list) s.EventType = eventType;
        Persist(eventType, list);
        Updated?.Invoke(list, eventType);
    }

    void Persist(string eventType, List<Snapshot> list)
    {
        lock (_persistLock)
        {
        EnsureDirs();
        var ts=Now(); var csv=Path.Combine(DataDir,$"exchange_snapshots_{DateTime.Now:yyyy-MM-dd}.csv");
        if (!File.Exists(csv)) File.WriteAllText(csv,"schema_version,ts,event_type,exchange,symbol,price,funding,equity,available,position,entry,mark,upnl,liq,open_orders,status,last_success,consecutive_failures\n",Encoding.UTF8);
        var sb=new StringBuilder();
        using var cn=new SqliteConnection($"Data Source={DbPath}"); cn.Open();
        foreach (var s in list)
        {
            var h=_health.GetOrAdd(s.Exchange,_=>new Health()); s.LastSuccess=h.LastSuccess; s.ConsecutiveFailures=h.ConsecutiveFailures;
            string[] vals={SchemaVersion,ts,eventType,s.Exchange,s.Symbol,s.Price,s.Funding,s.Equity,s.Available,s.Position,s.Entry,s.Mark,s.Upnl,s.Liq,s.OpenOrders,s.Status,s.LastSuccess,s.ConsecutiveFailures.ToString()};
            sb.AppendLine(string.Join(',', vals.Select(Csv)));
            using var cmd=cn.CreateCommand();
            cmd.CommandText="INSERT INTO snapshots(schema_version,ts,event_type,exchange,symbol,price,funding,equity,available,position,entry,mark,upnl,liq,open_orders,status,last_success,consecutive_failures) VALUES ($a,$b,$c,$d,$e,$f,$g,$h,$i,$j,$k,$l,$m,$n,$o,$p,$q,$r)";
            string[] names={"$a","$b","$c","$d","$e","$f","$g","$h","$i","$j","$k","$l","$m","$n","$o","$p","$q","$r"};
            for(int i=0;i<names.Length;i++) cmd.Parameters.AddWithValue(names[i], vals[i]); cmd.ExecuteNonQuery();
        }
        File.AppendAllText(csv,sb.ToString(),Encoding.UTF8);
        WriteHeartbeat(cn);
        WriteLatestSnapshot(eventType, ts, list);
        }
    }
    static string Csv(string s)=>"\""+(s??"").Replace("\"","\"\"")+"\"";

    void WriteLatestSnapshot(string eventType, string ts, List<Snapshot> list)
    {
        var obj = new { schema_version = SchemaVersion, ts, event_type = eventType, snapshots = list };
        File.WriteAllText(Path.Combine(DataDir, "latest_snapshot.json"), JsonSerializer.Serialize(obj, new JsonSerializerOptions{WriteIndented=true}), Encoding.UTF8);
    }

    void WriteHeartbeat(SqliteConnection cn)
    {
        var obj = new { schema_version=SchemaVersion, updated_at=Now(), exchanges=_health };
        File.WriteAllText(Path.Combine(DataDir,"heartbeat.json"), JsonSerializer.Serialize(obj,new JsonSerializerOptions{WriteIndented=true}), Encoding.UTF8);
        foreach (var kv in _health)
        {
            using var cmd=cn.CreateCommand();
            cmd.CommandText="INSERT OR REPLACE INTO heartbeat(exchange,schema_version,last_success,last_error,consecutive_failures,updated_at) VALUES($e,$v,$s,$r,$f,$u)";
            cmd.Parameters.AddWithValue("$e",kv.Key); cmd.Parameters.AddWithValue("$v",SchemaVersion); cmd.Parameters.AddWithValue("$s",kv.Value.LastSuccess); cmd.Parameters.AddWithValue("$r",kv.Value.LastError); cmd.Parameters.AddWithValue("$f",kv.Value.ConsecutiveFailures); cmd.Parameters.AddWithValue("$u",kv.Value.UpdatedAt); cmd.ExecuteNonQuery();
        }
    }

    void CleanupWorkspaceTrash()
    {
        try
        {
            foreach (var pat in new[] { "publish*", "package*", "tmp_sqlite", "tools" })
                foreach (var d in Directory.GetDirectories(BaseDir, pat)) Directory.Delete(d, true);
            foreach (var pat in new[] { "BTC-Realtime-Monitor-v*.exe", "BTC-Realtime-Monitor-v*.zip", "*.pdb" })
                foreach (var f in Directory.GetFiles(BaseDir, pat)) File.Delete(f);
            var csharp = Path.Combine(BaseDir, "csharp", "BtcCollector");
            foreach (var d in new[] { Path.Combine(csharp, "bin"), Path.Combine(csharp, "obj") })
                if (Directory.Exists(d)) Directory.Delete(d, true);
        }
        catch (Exception ex) { Log("清理临时文件失败：" + ex.Message); }
    }

    async Task CleanupLoop(CancellationToken ct)
    {
        while(!ct.IsCancellationRequested)
        {
            try { CleanupOldData(); } catch(Exception ex) { Log("清理旧数据失败："+ex.Message); }
            await Task.Delay(TimeSpan.FromHours(6), ct);
        }
    }
    public void CleanupOldData()
    {
        EnsureDirs();
        var cfg=LoadConfig(); var days=Math.Clamp(CfgInt(cfg,"RETENTION_DAYS",30,7),7,30); var cutoff=DateTime.Now.Date.AddDays(-days);
        foreach(var f in Directory.GetFiles(DataDir,"exchange_snapshots_*.csv"))
        {
            var name=Path.GetFileNameWithoutExtension(f).Replace("exchange_snapshots_","");
            if(DateTime.TryParseExact(name,"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out var d) && d<cutoff) File.Delete(f);
        }
        using var cn=new SqliteConnection($"Data Source={DbPath}"); cn.Open(); using var cmd=cn.CreateCommand();
        cmd.CommandText="DELETE FROM snapshots WHERE ts < $cutoff; VACUUM;"; cmd.Parameters.AddWithValue("$cutoff", cutoff.ToString("yyyy-MM-dd HH:mm:ss")); cmd.ExecuteNonQuery();
        Log($"自动清理完成：保留最近 {days} 天");
    }
}

public sealed class MainForm : Form
{
    readonly Collector _collector = new();
    readonly DataGridView _grid = new();
    readonly TextBox _log = new();
    readonly Label _status = new();
    readonly NotifyIcon _notify = new();
    readonly CheckBox _autoStart = new();
    IReadOnlyList<Snapshot> _lastSnaps = Array.Empty<Snapshot>();
    Icon? _statusIcon;
    readonly bool _startMinimized;
    bool _exit;

    public MainForm(string[] args)
    {
        _startMinimized = args.Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase) || a.Equals("/minimized", StringComparison.OrdinalIgnoreCase));
        Text="BTC实时通信系统 v2.3"; StartPosition=FormStartPosition.CenterScreen; MinimumSize=new Size(1180,620); Size=new Size(Math.Min(Screen.PrimaryScreen!.WorkingArea.Width - 120, 1380), Math.Min(Screen.PrimaryScreen.WorkingArea.Height - 120, 680)); Font=new Font("Microsoft YaHei UI",9);
        var main=new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(16),ColumnCount=1,RowCount=5};
        main.RowStyles.Add(new RowStyle(SizeType.AutoSize)); main.RowStyles.Add(new RowStyle(SizeType.AutoSize)); main.RowStyles.Add(new RowStyle(SizeType.Percent,100)); main.RowStyles.Add(new RowStyle(SizeType.Absolute,105)); main.RowStyles.Add(new RowStyle(SizeType.AutoSize)); Controls.Add(main);
        main.Controls.Add(new Label{Text="BTC数据采集器",AutoSize=true,Font=new Font("Microsoft YaHei UI",14,FontStyle.Bold),Margin=new Padding(0,0,0,8)},0,0);
        _status.Text="状态：启动中"; _status.AutoSize=true; _status.Margin=new Padding(0,0,0,10); main.Controls.Add(_status,0,1);
        _grid.Dock=DockStyle.Fill; _grid.ReadOnly=true; _grid.AllowUserToAddRows=false; _grid.AllowUserToDeleteRows=false; _grid.RowHeadersVisible=false; _grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill; _grid.AutoSizeRowsMode=DataGridViewAutoSizeRowsMode.AllCells; _grid.ScrollBars=ScrollBars.Vertical; _grid.DefaultCellStyle.WrapMode=DataGridViewTriState.False; _grid.ColumnHeadersDefaultCellStyle.WrapMode=DataGridViewTriState.False; _grid.SelectionMode=DataGridViewSelectionMode.FullRowSelect;
        foreach(var c in new[]{("exchange","交易所"),("symbol","合约"),("price","价格"),("funding","资金"),("equity","权益"),("available","可用"),("position","持仓"),("entry","开仓"),("mark","标记"),("upnl","盈亏"),("liq","强平"),("orders","挂单"),("status","状态"),("last","成功"),("fail","失败")}) _grid.Columns.Add(c.Item1,c.Item2);
        SetColumnWeights();
        main.Controls.Add(_grid,0,2);
        _log.Multiline=true; _log.ReadOnly=true; _log.ScrollBars=ScrollBars.Vertical; _log.Dock=DockStyle.Fill; _log.Font=new Font("Consolas",9); main.Controls.Add(_log,0,3);
        var buttons=new FlowLayoutPanel{Dock=DockStyle.Fill,Height=48,WrapContents=false,Margin=new Padding(0,12,0,0)}; main.Controls.Add(buttons,0,4);
        var refresh=new Button{Text="立即刷新",MinimumSize=new Size(100,34)}; refresh.Click += async (_,_)=> await _collector.RefreshNow(); buttons.Controls.Add(refresh);
        _autoStart.Text="开机自启动"; _autoStart.AutoSize=true; _autoStart.Checked=true; _autoStart.Margin=new Padding(14,8,3,3); _autoStart.CheckedChanged += (_,_)=>SetAutoStart(_autoStart.Checked); buttons.Controls.Add(_autoStart);
        var config=new Button{Text="配置",MinimumSize=new Size(80,34),Margin=new Padding(12,3,3,3)}; config.Click += (_,_)=>OpenConfig(); buttons.Controls.Add(config);
        var openData=new Button{Text="打开数据目录",MinimumSize=new Size(120,34),Margin=new Padding(12,3,3,3)}; openData.Click += (_,_)=>OpenDataDir(); buttons.Controls.Add(openData);
        var hide=new Button{Text="隐藏到托盘",MinimumSize=new Size(120,34),Margin=new Padding(12,3,3,3)}; hide.Click += (_,_)=>HideToTray(); buttons.Controls.Add(hide);
        var exit=new Button{Text="退出程序",MinimumSize=new Size(100,34),Margin=new Padding(12,3,3,3)}; exit.Click += (_,_)=>ExitApp(); buttons.Controls.Add(exit);
        _notify.Icon=CreateStatusIcon(false); _notify.Text="BTC数据采集器 启动中"; _notify.Visible=true; var menu=new ContextMenuStrip(); menu.Items.Add("显示窗口",null,(_,_)=>ShowWindow()); menu.Items.Add("隐藏窗口",null,(_,_)=>HideToTray()); menu.Items.Add("退出程序",null,(_,_)=>ExitApp()); _notify.ContextMenuStrip=menu; _notify.DoubleClick += (_,_)=>ShowWindow();
        Resize += (_,_)=> { if(WindowState==FormWindowState.Minimized) HideToTray(); };
        FormClosing += (_,e)=> { if(!_exit && e.CloseReason==CloseReason.UserClosing){ e.Cancel=true; HideToTray(); }};
        _collector.Updated += (snaps,evt)=> BeginInvoke(()=>UpdateGrid(snaps,evt));
        _collector.LogLine += line => BeginInvoke(()=>AppendLog(line));
        Shown += (_,_)=> { SyncAutoStartCheckbox(); SetAutoStart(_autoStart.Checked); _collector.Start(); if (_startMinimized) BeginInvoke(HideToTray); };
    }
    void UpdateGrid(IReadOnlyList<Snapshot> snaps,string evt)
    {
        _lastSnaps = snaps;
        _grid.SuspendLayout(); _grid.Rows.Clear();
        foreach(var s in snaps)
        {
            var idx = _grid.Rows.Add(ShortEx(s.Exchange),s.Symbol,Fmt(s.Price,1),s.Funding,Money(s.Exchange,s.Equity,"equity"),Money(s.Exchange,s.Available,"available"),Pos(s.Exchange,s.Position),Fmt(s.Entry,1),Fmt(s.Mark,1),Money(s.Exchange,s.Upnl,"upnl"),Fmt(s.Liq,1),s.OpenOrders,s.Status,ShortTime(s.LastSuccess),s.ConsecutiveFailures);
            var row = _grid.Rows[idx];
            var ok = s.Status == "OK" && s.ConsecutiveFailures == 0;
            row.Cells[12].Style.BackColor = ok ? Color.FromArgb(210,245,210) : Color.FromArgb(255,210,210);
            row.Cells[12].Style.ForeColor = ok ? Color.DarkGreen : Color.DarkRed;
            row.DefaultCellStyle.BackColor = ok ? Color.White : Color.FromArgb(255,245,245);
        }
        _grid.ResumeLayout();
        var allOk = snaps.Count > 0 && snaps.All(x => x.Status == "OK" && x.ConsecutiveFailures == 0);
        _status.Text=$"状态：{evt}｜{DateTime.Now:HH:mm:ss}｜WebSocket｜schema 2.3.0";
        UpdateTray(allOk, snaps);
    }
    void SetColumnWeights()
    {
        var weights = new Dictionary<string,float>{{"exchange",85},{"symbol",105},{"price",78},{"funding",70},{"equity",95},{"available",95},{"position",110},{"entry",78},{"mark",78},{"upnl",95},{"liq",78},{"orders",55},{"status",70},{"last",70},{"fail",45}};
        foreach (DataGridViewColumn col in _grid.Columns)
        {
            col.AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
            col.FillWeight = weights.TryGetValue(col.Name, out var w) ? w : 70;
            col.MinimumWidth = 40;
        }
    }
    static string ShortEx(string ex) => ex.StartsWith("Binance") ? "Binance" : ex.StartsWith("OKX") ? "OKX" : ex;
    static string ShortTime(string t) => DateTime.TryParse(t, out var dt) ? dt.ToString("HH:mm:ss") : "--";
    static string Money(string ex,string v,string field) => ex.StartsWith("OKX") ? Add(v,"BTC",4) : Add(v,"USDT",1);
    static string Add(string v,string unit,int d){ var f=Fmt(v,d); return f=="--"?"--":$"{f} {unit}"; }
    static string Fmt(string v,int d)=> decimal.TryParse(v,NumberStyles.Any,CultureInfo.InvariantCulture,out var n)?n.ToString("F"+d):"--";
    static string Pos(string ex,string v)
    {
        if(string.IsNullOrWhiteSpace(v)||v=="--") return "--";
        if(ex.StartsWith("OKX")) { if(v.StartsWith("short ")) return "空 "+Fmt(v[6..],1)+" 张"; if(v.StartsWith("long ")) return "多 "+Fmt(v[5..],1)+" 张"; return Fmt(v,1)+" 张"; }
        if(decimal.TryParse(v,NumberStyles.Any,CultureInfo.InvariantCulture,out var n)) return n>0?$"多 {n:F4} BTC":n<0?$"空 {Math.Abs(n):F4} BTC":"无 0 BTC"; return v;
    }
    void UpdateTray(bool ok, IReadOnlyList<Snapshot> snaps)
    {
        _statusIcon?.Dispose();
        _statusIcon = CreateStatusIcon(ok);
        _notify.Icon = _statusIcon;
        var okx = snaps.FirstOrDefault(x => x.Exchange.StartsWith("OKX"));
        var binance = snaps.FirstOrDefault(x => x.Exchange.StartsWith("Binance"));
        var summary = $"BTC采集 {(ok ? "正常" : "异常")} | B {Fmt(binance?.Price ?? "",1)} | O {Fmt(okx?.Price ?? "",1)}";
        if (summary.Length > 63) summary = summary[..63];
        _notify.Text = summary;
    }
    static Icon CreateStatusIcon(bool ok)
    {
        using var bmp = new Bitmap(16,16);
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.Transparent);
        using var brush = new SolidBrush(ok ? Color.LimeGreen : Color.Red);
        using var pen = new Pen(Color.White, 2);
        g.FillEllipse(brush, 1,1,14,14);
        g.DrawEllipse(pen, 1,1,14,14);
        return Icon.FromHandle(bmp.GetHicon());
    }
    void OpenDataDir()
    {
        try
        {
            Directory.CreateDirectory(_collector.DataDir);
            Process.Start(new ProcessStartInfo { FileName = _collector.DataDir, UseShellExecute = true });
        }
        catch (Exception ex) { AppendLog("打开数据目录失败：" + ex.Message); }
    }
    void OpenConfig()
    {
        using var dlg = new ConfigForm(_collector);
        if (dlg.ShowDialog(this) == DialogResult.OK)
        {
            AppendLog("配置已保存，部分连接参数重启程序后完全生效");
            _ = _collector.RefreshNow();
        }
    }
    void SyncAutoStartCheckbox()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false);
            var v = key?.GetValue("BTC实时通信系统") as string;
            _autoStart.Checked = string.IsNullOrWhiteSpace(v) ? true : v.Contains(Application.ExecutablePath, StringComparison.OrdinalIgnoreCase);
        }
        catch { _autoStart.Checked = true; }
    }
    void SetAutoStart(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true) ?? Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (enabled) key.SetValue("BTC实时通信系统", $"\"{Application.ExecutablePath}\" --minimized");
            else key.DeleteValue("BTC实时通信系统", false);
        }
        catch (Exception ex) { AppendLog("设置开机自启动失败：" + ex.Message); }
    }
    void AppendLog(string line){ _log.AppendText(line+Environment.NewLine); }
    void HideToTray(){ Hide(); _notify.ShowBalloonTip(800,"BTC数据采集器","程序已隐藏到托盘",ToolTipIcon.Info); }
    void ShowWindow(){ Show(); WindowState=FormWindowState.Normal; Activate(); }
    void ExitApp(){ _exit=true; _collector.Stop(); _notify.Visible=false; _notify.Dispose(); _statusIcon?.Dispose(); Close(); Application.Exit(); }
}

public sealed class ConfigForm : Form
{
    readonly Collector _collector;
    readonly Dictionary<string, TextBox> _boxes = new();
    readonly Dictionary<string, CheckBox> _checks = new();
    readonly NumericUpDown _price = new(){Minimum=1,Maximum=60,Value=3};
    readonly NumericUpDown _account = new(){Minimum=5,Maximum=300,Value=10};
    readonly NumericUpDown _funding = new(){Minimum=30,Maximum=3600,Value=60};
    readonly NumericUpDown _retention = new(){Minimum=7,Maximum=30,Value=30};
    public ConfigForm(Collector collector)
    {
        _collector = collector;
        Text = "配置";
        StartPosition = FormStartPosition.CenterParent;
        Size = new Size(620, 620);
        MinimumSize = new Size(620, 620);
        Font = new Font("Microsoft YaHei UI", 9);
        var cfg = _collector.LoadConfig();
        var panel = new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(14),ColumnCount=2,AutoScroll=true};
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,170));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        Controls.Add(panel);
        int r=0;
        AddCheck(panel, ref r, "BINANCE_ENABLED", "启用Binance", cfg.GetValueOrDefault("BINANCE_ENABLED","true") != "false", "测试Binance");
        AddBox(panel, ref r, "BINANCE_API_KEY", "Binance API Key", cfg.GetValueOrDefault("BINANCE_API_KEY",""));
        AddBox(panel, ref r, "BINANCE_API_SECRET", "Binance Secret", cfg.GetValueOrDefault("BINANCE_API_SECRET",""), true);
        AddBox(panel, ref r, "BINANCE_SYMBOL", "Binance合约", cfg.GetValueOrDefault("BINANCE_SYMBOL","BTCUSDT"));
        AddCheck(panel, ref r, "OKX_ENABLED", "启用OKX", cfg.GetValueOrDefault("OKX_ENABLED","true") != "false", "测试OKX");
        AddBox(panel, ref r, "OKX_API_KEY", "OKX API Key", cfg.GetValueOrDefault("OKX_API_KEY",""));
        AddBox(panel, ref r, "OKX_API_SECRET", "OKX Secret", cfg.GetValueOrDefault("OKX_API_SECRET",""), true);
        AddBox(panel, ref r, "OKX_API_PASSPHRASE", "OKX Passphrase", cfg.GetValueOrDefault("OKX_API_PASSPHRASE",""), true);
        AddBox(panel, ref r, "OKX_INST_ID", "OKX合约", cfg.GetValueOrDefault("OKX_INST_ID","BTC-USD-SWAP"));
        AddNum(panel, ref r, "价格刷新/落库秒", _price, cfg.GetValueOrDefault("PRICE_REFRESH_SECONDS","3"));
        AddNum(panel, ref r, "账户刷新秒", _account, cfg.GetValueOrDefault("ACCOUNT_REFRESH_SECONDS","10"));
        AddNum(panel, ref r, "资金费率秒", _funding, cfg.GetValueOrDefault("FUNDING_REFRESH_SECONDS","60"));
        AddOutputDir(panel, ref r, cfg.GetValueOrDefault("DATA_OUTPUT_DIR", ""));
        AddNum(panel, ref r, "数据保留天数", _retention, cfg.GetValueOrDefault("RETENTION_DAYS","30"));
        var buttons = new FlowLayoutPanel{FlowDirection=FlowDirection.RightToLeft,Dock=DockStyle.Fill,Height=45};
        var ok = new Button{Text="保存",DialogResult=DialogResult.OK,Width=90,Height=32};
        ok.Click += (_,_) => Save();
        var cancel = new Button{Text="取消",DialogResult=DialogResult.Cancel,Width=90,Height=32};
        buttons.Controls.Add(ok); buttons.Controls.Add(cancel);
        panel.RowStyles.Add(new RowStyle(SizeType.Absolute,50)); panel.Controls.Add(buttons,0,r); panel.SetColumnSpan(buttons,2);
    }
    void AddCheck(TableLayoutPanel p, ref int r, string key, string label, bool value, string? testButton=null)
    {
        p.RowStyles.Add(new RowStyle(SizeType.Absolute,38));
        p.Controls.Add(new Label{Text=label,AutoSize=true,Anchor=AnchorStyles.Left},0,r);
        var flow = new FlowLayoutPanel{Dock=DockStyle.Fill,WrapContents=false};
        var c=new CheckBox{Checked=value,AutoSize=true,Margin=new Padding(0,8,12,0)}; _checks[key]=c; flow.Controls.Add(c);
        if (testButton != null)
        {
            var b = new Button{Text=testButton,Width=100,Height=28};
            b.Click += async (_,_) => { Save(); b.Enabled=false; b.Text="测试中..."; var msg = await _collector.TestConnection(testButton.Contains("Binance") ? "Binance" : "OKX"); b.Text=testButton; b.Enabled=true; MessageBox.Show(this,msg,"测试连接",MessageBoxButtons.OK, msg.Contains("失败") ? MessageBoxIcon.Warning : MessageBoxIcon.Information); };
            flow.Controls.Add(b);
        }
        p.Controls.Add(flow,1,r++);
    }
    void AddBox(TableLayoutPanel p, ref int r, string key, string label, string value, bool secret=false)
    {
        p.RowStyles.Add(new RowStyle(SizeType.Absolute,36));
        p.Controls.Add(new Label{Text=label,AutoSize=true,Anchor=AnchorStyles.Left},0,r);
        var t=new TextBox{Text=value,Dock=DockStyle.Fill,UseSystemPasswordChar=secret}; _boxes[key]=t; p.Controls.Add(t,1,r++);
    }
    void AddOutputDir(TableLayoutPanel p, ref int r, string value)
    {
        p.RowStyles.Add(new RowStyle(SizeType.Absolute,38));
        p.Controls.Add(new Label{Text="输出目录",AutoSize=true,Anchor=AnchorStyles.Left},0,r);
        var flow = new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2};
        flow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        flow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,80));
        var t = new TextBox{Text=value,Dock=DockStyle.Fill}; _boxes["DATA_OUTPUT_DIR"] = t; flow.Controls.Add(t,0,0);
        var b = new Button{Text="选择",Dock=DockStyle.Fill};
        b.Click += (_,_) => { using var f = new FolderBrowserDialog{Description="选择数据输出目录"}; if (f.ShowDialog(this)==DialogResult.OK) t.Text=f.SelectedPath; };
        flow.Controls.Add(b,1,0);
        p.Controls.Add(flow,1,r++);
    }
    void AddNum(TableLayoutPanel p, ref int r, string label, NumericUpDown n, string value)
    {
        if (decimal.TryParse(value, out var v)) n.Value=Math.Min(n.Maximum, Math.Max(n.Minimum, v));
        p.RowStyles.Add(new RowStyle(SizeType.Absolute,36));
        p.Controls.Add(new Label{Text=label,AutoSize=true,Anchor=AnchorStyles.Left},0,r);
        n.Dock=DockStyle.Left; p.Controls.Add(n,1,r++);
    }
    void Save()
    {
        var cfg = _collector.LoadConfig();
        foreach (var kv in _boxes) cfg[kv.Key]=kv.Value.Text.Trim();
        foreach (var kv in _checks) cfg[kv.Key]=kv.Value.Checked ? "true" : "false";
        cfg["PRICE_REFRESH_SECONDS"]=_price.Value.ToString(CultureInfo.InvariantCulture);
        cfg["ACCOUNT_REFRESH_SECONDS"]=_account.Value.ToString(CultureInfo.InvariantCulture);
        cfg["FUNDING_REFRESH_SECONDS"]=_funding.Value.ToString(CultureInfo.InvariantCulture);
        cfg["RETENTION_DAYS"]=_retention.Value.ToString(CultureInfo.InvariantCulture);
        _collector.SaveConfig(cfg);
    }
}

