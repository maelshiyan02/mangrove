/* ============================================================
 * 精简 AES-128-CBC (纯 JS 无依赖, QuickJS 沙箱可用)
 * 拷贝网页端: key=16字节ASCII(ccz/cct), iv=密文前16字符ASCII,
 *            其余为 hex 密文, Pkcs7 填充
 * 已通过 NIST SP800-38A 向量 + 真实章节/阅读器密文交叉验证
 * ============================================================ */
var CopyAES = (function () {
    function gmul(a, b) {
        var p = 0;
        for (var i = 0; i < 8; i++) {
            if (b & 1) p ^= a;
            var hi = a & 0x80;
            a = (a << 1) & 0xff;
            if (hi) a ^= 0x1b;
            b >>= 1;
        }
        return p;
    }
    function ginv(b) {
        if (b === 0) return 0;
        for (var i = 1; i < 256; i++) if (gmul(b, i) === 1) return i;
        return 0;
    }
    function rotl8(v, n) { return ((v << n) | (v >>> (8 - n))) & 0xff; }
    var SBOX = new Array(256), ISBOX = new Array(256);
    (function () {
        for (var i = 0; i < 256; i++) {
            var x = ginv(i);
            var s = x ^ rotl8(x, 1) ^ rotl8(x, 2) ^ rotl8(x, 3) ^ rotl8(x, 4) ^ 0x63;
            SBOX[i] = s & 0xff;
            ISBOX[s & 0xff] = i;
        }
    })();
    var RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];
    function keyExpansion(key) {
        var w = new Array(44);
        for (var i = 0; i < 4; i++)
            w[i] = [key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]];
        for (i = 4; i < 44; i++) {
            var t = w[i - 1].slice();
            if (i % 4 === 0) {
                t = [t[1], t[2], t[3], t[0]];
                t = [SBOX[t[0]], SBOX[t[1]], SBOX[t[2]], SBOX[t[3]]];
                t[0] ^= RCON[i / 4];
            }
            var p = w[i - 4];
            w[i] = [p[0] ^ t[0], p[1] ^ t[1], p[2] ^ t[2], p[3] ^ t[3]];
        }
        return w;
    }
    function addRoundKey(state, w, round) {
        for (var c = 0; c < 4; c++) {
            var k = w[round * 4 + c];
            state[0][c] ^= k[0]; state[1][c] ^= k[1];
            state[2][c] ^= k[2]; state[3][c] ^= k[3];
        }
    }
    function invSubBytes(state) {
        for (var r = 0; r < 4; r++)
            for (var c = 0; c < 4; c++) state[r][c] = ISBOX[state[r][c]];
    }
    function invShiftRows(state) {
        for (var r = 1; r < 4; r++) {
            var row = [state[r][0], state[r][1], state[r][2], state[r][3]];
            for (var c = 0; c < 4; c++) state[r][c] = row[(c - r + 4) % 4];
        }
    }
    function invMixColumns(state) {
        for (var c = 0; c < 4; c++) {
            var a0 = state[0][c], a1 = state[1][c], a2 = state[2][c], a3 = state[3][c];
            state[0][c] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
            state[1][c] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
            state[2][c] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
            state[3][c] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
        }
    }
    function decryptBlock(block, w) {
        var state = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
        for (var c = 0; c < 4; c++)
            for (var r = 0; r < 4; r++) state[r][c] = block[c * 4 + r];
        addRoundKey(state, w, 10);
        for (var round = 9; round >= 1; round--) {
            invShiftRows(state); invSubBytes(state);
            addRoundKey(state, w, round); invMixColumns(state);
        }
        invShiftRows(state); invSubBytes(state); addRoundKey(state, w, 0);
        var out = new Array(16);
        for (c = 0; c < 4; c++)
            for (r = 0; r < 4; r++) out[c * 4 + r] = state[r][c];
        return out;
    }
    function hexToBytes(hex) {
        var out = new Array(hex.length / 2);
        for (var i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
        return out;
    }
    function utf8ToBytes(str) {
        var bytes = [];
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i);
            if (c < 0x80) bytes.push(c);
            else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
            else if (c < 0xd800 || c >= 0xe000)
                bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
            else {
                i++;
                var cp = 0x10000 + (((c & 0x3ff) << 10) | (str.charCodeAt(i) & 0x3ff));
                bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
                    0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
            }
        }
        return bytes;
    }
    function bytesToUtf8(bytes) {
        var out = "", i = 0;
        while (i < bytes.length) {
            var b = bytes[i++];
            if (b < 0x80) out += String.fromCharCode(b);
            else if ((b & 0xe0) === 0xc0)
                out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f));
            else if ((b & 0xf0) === 0xe0)
                out += String.fromCharCode(((b & 0x0f) << 12) |
                    ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
            else {
                var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) |
                    ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
                cp -= 0x10000;
                out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
            }
        }
        return out;
    }
    function stripPkcs7(plain) {
        var pad = plain[plain.length - 1];
        if (pad < 1 || pad > 16) return plain;
        for (var k = plain.length - pad; k < plain.length; k++)
            if (plain[k] !== pad) return plain;
        return plain.slice(0, plain.length - pad);
    }
    function decryptPayload(keyStr, payload) {
        var iv = [];
        for (var i = 0; i < 16; i++) iv.push(payload.charCodeAt(i));
        var ct = hexToBytes(payload.substring(16));
        var key = utf8ToBytes(keyStr);
        var w = keyExpansion(key);
        var plain = [], prev = iv;
        for (var off = 0; off < ct.length; off += 16) {
            var block = ct.slice(off, off + 16);
            var dec = decryptBlock(block, w);
            for (var j = 0; j < 16; j++) plain.push(dec[j] ^ prev[j]);
            prev = block;
        }
        return bytesToUtf8(stripPkcs7(plain));
    }
    return { decryptPayload: decryptPayload };
})();

class CopyManga extends ComicSource {
    name = "拷贝漫画"
    key = "copy_manga"
    version = "1.8.0"
    minAppVersion = "1.6.0"
    url = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/copy_manga.js"

    //====修改====【新增自动重置设备指纹函数】
    /**
     * 重置设备指纹：删除本地持久化存储，下一次读取headers getter自动生成全新设备信息
     */
    autoResetDeviceFingerprint() {
        // 记录刚用过的指纹，下次生成时优先避开，避免放回式抽取连续撞同一设备
        const oldInfo = this.loadData("_deviceinfo");
        const oldDev = this.loadData("_device");
        this.deleteData("_deviceinfo");
        this.deleteData("_device");
        this.deleteData("_pseudoid");
        this.deleteData("_virtual_ip");
        if (oldInfo) this.saveData("_exclude_deviceinfo", oldInfo);
        if (oldDev) this.saveData("_exclude_device", oldDev);
        this.refreshAppApi();
    }
    /**
     * 记录本会话内被风控(210)的设备指纹，后续生成时优先排除，池子用尽才允许复用
     */
    loadBlockedDevices() {
        let raw = this.loadData("_blocked_deviceinfos");
        if (Array.isArray(raw)) return raw;
        try {
            return JSON.parse(raw || "[]");
        } catch (e) {
            return [];
        }
    }
    saveBlockedDevices(list) {
        this.saveData("_blocked_deviceinfos", JSON.stringify(list.slice(-30)));
    }
    markDeviceBlocked() {
        const cur = this.loadData("_deviceinfo");
        if (!cur) return;
        const list = this.loadBlockedDevices();
        if (!list.includes(cur)) {
            list.push(cur);
            this.saveBlockedDevices(list);
        }
    }
    /**
     * 从指纹池挑选新设备：排除刚用过的 + 本会话被封过的；全部被排除时降级回退
     */
    pickDeviceItem() {
        const excludeInfo = this.loadData("_exclude_deviceinfo");
        const blocked = this.loadBlockedDevices();
        let pool = CopyManga.realDevicePool;
        let candidates = pool.filter(item =>
            item.deviceinfo !== excludeInfo && !blocked.includes(item.deviceinfo)
        );
        if (candidates.length === 0) {
            candidates = pool.filter(item => item.deviceinfo !== excludeInfo);
        }
        if (candidates.length === 0) {
            candidates = pool;
        }
        return candidates[Math.floor(Math.random() * candidates.length)];
    }
    //====结束修改====

    // 高级节流与随机抖动控制（模拟真人阅读防范应用层风控）
    async throttle() {
        let lastReq = this.loadData("_last_req_time") || 0;
        let now = Date.now();
        let diff = now - parseInt(lastReq);
        // 动态随机延迟 600ms - 1200ms，避开固定频率特征检测
        let targetDelay = 600 + Math.floor(Math.random() * 600);
        if (diff < targetDelay) {
            let wait = targetDelay - diff;
            await new Promise((resolve) => setTimeout(resolve, wait));
        }
        this.saveData("_last_req_time", Date.now().toString());
    }
    // 获取动态广告 request_id 绕过校验
    async getReqID() {
        if (this.copyRegion === "0") {
            return "";
        }
        const reqIdUrl = "https://marketing.aiacgn.com/api/v2/adopr/query3/?format=json&ident=200100001";
        let reqId = "";
        try {
            await this.throttle();
            const response = await Network.get(reqIdUrl, this.headers);
            if (response.status === 200) {
                const data = JSON.parse(response.body);
                reqId = data.results.request_id;
            }
        } catch (e) {
        }
        return reqId;
    }
    // 严格对齐官方 3.0.9 App 的 Header 键值顺序及特征
    get headers() {
        let token = this.loadData("token");
        let secret = "M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM="
        let now = new Date(Date.now());
        let year = now.getFullYear();
        let month = (now.getMonth() + 1).toString().padStart(2, '0');
        let day = now.getDate().toString().padStart(2, '0');
        let ts = Math.floor(now.getTime() / 1000).toString()
        if (!token) {
            token = "";
        } else {
            token = " " + token;
        }
        let sig = Convert.hmacString(
            Convert.decodeBase64(secret),
            Convert.encodeUtf8(ts),
            "sha256"
        )
        // 严格按照官方 App 的 Header 字典键顺序返回，对抗 WAF/TLS 指纹关联审计
        let h = {
            "User-Agent": "COPY/3.0.9",
            "source": "copyApp",
            "deviceinfo": this.deviceinfo,
            "dt": `${year}.${month}.${day}`,
            "platform": "3",
            "referer": "com.copymanga.app-3.0.9",
            "version": "3.0.9",
            "device": this.device,
            "pseudoid": this.pseudoid,
            "Accept": "application/json",
            "region": this.copyRegion,
            "authorization": `Token${token}`,
            "umstring": "b4c89ca4104ea9a97750314d791520ac",
            "x-auth-timestamp": ts,
            "x-auth-signature": sig,
        };
        // 实验性：虚拟IP轮换（X-Forwarded-For/X-Real-IP），默认关闭
        if (this.loadSetting('enable_virtual_ip') === "1") {
            const vip = this.virtualIp;
            if (vip) {
                h["X-Forwarded-For"] = vip;
                h["X-Real-IP"] = vip;
            }
        }
        return h;
    }
    static defaultCopyRegion = "0"
    static defaultImageQuality = "1500"
    static defaultApiUrl = 'api.copy2000.online'
    //====修改(v1.7.0)====域名自动追踪: 引导域列表(任一存活即可发现当前官方域名)
    //API引导域: 依次请求官方 network2 域名发现接口
    static bootstrapApiHosts = [
        'api.copy-manga.com',
        'api.copy2000.online',
        'api.copy4000.com',
        'api.copy5000.com',
        'api.copy202601.com'
    ]
    //网页引导域: 用于抓取 const countApi (搜索接口路径)
    static bootstrapWebHosts = [
        'www.copy5000.com',
        'www.copy4000.com',
        'www.copy20.com'
    ]
    //====结束修改====
    static searchApi = "/api/kb/web/searchci/comics"
    // 高级真实设备指纹池（模拟主流安卓/iOS机型，避免特征单一）
    static realDevicePool = [
        { deviceinfo: "3371150V-9327", device: "EB0O.675141.548" },
        { deviceinfo: "4482161V-8412", device: "SM-S9180.827361.012" },
        { deviceinfo: "5593272V-7523", device: "23127PN0CC.918234.331" },
        { deviceinfo: "6604383V-6634", device: "V2309A.547182.194" },
        { deviceinfo: "7712265V-3218", device: "SM-S9110.332418.905" },
        { deviceinfo: "8823374V-2564", device: "2201123C.681220.114" },
        { deviceinfo: "9934483V-7412", device: "LIO-AL00.419362.207" },
        { deviceinfo: "1045592V-1856", device: "PHK110.755014.426" },
        { deviceinfo: "2156601V-6639", device: "V2183A.890227.538" },
        { deviceinfo: "3267710V-9475", device: "GX7A4.204516.772" },
        { deviceinfo: "4378829V-3027", device: "SM-A5460.135802.649" },
        { deviceinfo: "5489938V-8145", device: "PJA110.462917.381" }
    ];
    // 真实公网IP池（海外线路）：Cloudflare/Google/Quad9/OpenDNS/Yandex/Verisign 等公开DNS任播地址
    static virtualIpPoolOverseas = [
        "1.1.1.1", "1.0.0.1", "1.1.1.2",
        "8.8.8.8", "8.8.4.4", "8.26.56.26",
        "9.9.9.9", "76.76.2.0",
        "208.67.222.222", "208.67.220.220",
        "77.88.8.8", "64.6.64.6", "91.239.100.100",
        "185.228.168.9", "146.112.61.2", "84.200.69.80"
    ];
    // 真实公网IP池（大陆线路）：114DNS/AliDNS/Baidu/DNSPod/CNNIC 等国内公开DNS地址
    static virtualIpPoolMainland = [
        "114.114.114.114", "114.114.115.115",
        "223.5.5.5", "223.6.6.6",
        "180.76.76.76", "123.125.81.6",
        "119.29.29.29", "1.2.4.8", "210.2.4.8", "101.226.4.6"
    ];
    get deviceinfo() {
        let info = this.loadData("_deviceinfo");
        if (!info) {
            let item = this.pickDeviceItem();
            info = item.deviceinfo;
            this.saveData("_deviceinfo", info);
            this.saveData("_device", item.device);
        }
        return info;
    }
    get device() {
        let dev = this.loadData("_device");
        if (!dev) {
            let item = this.pickDeviceItem();
            dev = item.device;
            this.saveData("_device", dev);
            this.saveData("_deviceinfo", item.deviceinfo);
        }
        return dev;
    }
    get virtualIp() {
        if (this.loadSetting('enable_virtual_ip') !== "1") {
            return "";
        }
        let ip = this.loadData("_virtual_ip");
        if (!ip) {
            const pool = this.copyRegion === "1"
                ? CopyManga.virtualIpPoolMainland
                : CopyManga.virtualIpPoolOverseas;
            ip = pool[Math.floor(Math.random() * pool.length)];
            this.saveData("_virtual_ip", ip);
        }
        return ip;
    }
    get pseudoid() {
        let pid = this.loadData("_pseudoid");
        if (!pid) {
            const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
            pid = '';
            for (let i = 0; i < 16; i++) {
                pid += chars.charAt(Math.floor(Math.random() * chars.length));
            }
            this.saveData("_pseudoid", pid);
        }
        return pid;
    }
    //====修改(v1.7.0)====域名自动追踪核心
    //当前会话正在使用的API主机
    _currentHost = null
    //进行中的域名发现任务(避免重复请求)
    _discoverPromise = null
    //用户手动指定的API主机(仅当与内置默认不同), 故障转移时仍会尝试, 但发现到的官方地址优先
    get manualApiHost() {
        const v = this.loadSetting('base_url')
        return v && v !== CopyManga.defaultApiUrl ? v : null
    }
    get apiUrl() {
        return `https://${this._currentHost
            || this.loadData('_api_host')
            || this.manualApiHost
            || CopyManga.defaultApiUrl}`
    }
    //构造API主机候选列表(去重, 仅接受域名格式)
    apiHostCandidates() {
        const list = []
        const push = (v) => {
            if (v && /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i.test(String(v)) && !list.includes(v)) {
                list.push(v)
            }
        }
        push(this._currentHost)
        push(this.manualApiHost)
        push(this.loadData('_api_host'))
        let saved = this.loadData('_api_candidates')
        if (Array.isArray(saved)) {
            saved.forEach(push)
        } else if (saved) {
            try { JSON.parse(saved).forEach(push) } catch (e) { }
        }
        CopyManga.bootstrapApiHosts.forEach(push)
        push(CopyManga.defaultApiUrl)
        return list
    }
    /**
     * 官方域名发现: GET /api/v3/system/network2?platform=3 (必须带官方签名头, 否则返回蜜罐地址)
     * 拿到 results.api / results.share 后, 逐个用真实业务接口(homeIndex)验证再持久化
     * force=false 时使用12小时缓存
     */
    async discoverApiHosts(force = false) {
        const ts = parseInt(this.loadData('_api_host_ts') || '0')
        const cached = this.loadData('_api_candidates')
        if (!force && cached && Date.now() - ts < 12 * 3600 * 1000) {
            try {
                const arr = JSON.parse(cached)
                if (Array.isArray(arr) && arr.length) {
                    return arr
                }
            } catch (e) { }
        }
        const existing = this.apiHostCandidates()
        const collected = []
        const addAll = (arr) => {
            arr.forEach(v => {
                if (v && /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i.test(String(v)) && !collected.includes(v)) {
                    collected.push(v)
                }
            })
        }
        //依次查询引导域, 任一成功即可(官方宣布的域名排最前, 失效老域作为兜底)
        for (const metaHost of CopyManga.bootstrapApiHosts) {
            let announced = []
            let webHosts = []
            try {
                const res = await Network.get(
                    `https://${metaHost}/api/v3/system/network2?platform=3`,
                    this.headers
                )
                if (res.status !== 200) continue
                const data = JSON.parse(res.body)
                const r = data && data.results
                if (!r) continue
                if (Array.isArray(r.api)) {
                    r.api.forEach(row => {
                        if (Array.isArray(row)) {
                            row.forEach(x => announced.push(x))
                        } else {
                            announced.push(row)
                        }
                    })
                }
                if (Array.isArray(r.share)) {
                    webHosts = r.share.filter(x => typeof x === 'string')
                }
            } catch (e) {
                continue
            }
            //官方宣布的API域优先; 网页分享域推导 api 子域; 已知/引导域兜底
            addAll(announced)
            addAll(webHosts.map(w => w.replace(/^www\./i, 'api.')))
            if (webHosts.length) {
                this.saveData('_web_hosts', JSON.stringify(webHosts))
            }
            if (announced.length) break
        }
        addAll(existing)
        //业务验证: 蜜罐/失效域名会超时或返回非业务数据, 一律拒绝
        const validated = []
        for (const host of collected) {
            if (validated.length >= 3) break
            try {
                const res = await Network.get(
                    `https://${host}/api/v3/h5/homeIndex`,
                    this.headers
                )
                if (res.status === 200 && JSON.parse(res.body).code === 200) {
                    validated.push(host)
                }
            } catch (e) { }
        }
        if (validated.length) {
            this.saveData('_api_candidates', JSON.stringify(validated))
            this.saveData('_api_host', validated[0])
            this.saveData('_api_host_ts', Date.now().toString())
            return validated
        }
        return existing
    }
    //记录成功使用的主机(只更新当前指针, 不改候选列表)
    _rememberApiHost(host) {
        if (!host || this.loadData('_api_host') === host) return
        try {
            this.saveData('_api_host', host)
            this.saveData('_api_host_ts', Date.now().toString())
        } catch (e) { }
    }
    //判断异常是否属于域名/网络层故障(可切换域名重试); 210风控/404/业务错误不切换
    _isHostError(e) {
        const m = String((e && e.message) || e || "")
        if (/^210/.test(m) || /Login expired/i.test(m)) return false
        const st = m.match(/invalid status code:\s*(\d+)/i)
        if (st) {
            const c = parseInt(st[1])
            return c === 403 || c === 429 || c === 444 || c === 521 || c === 522 || c === 523 || c === 526 || c >= 500
        }
        return /timeout|timed out|handshake|connection\s*(?:reset|closed|refused|aborted|failed|error)|failed host lookup|getaddrinfo|socket\s*(?:exception|hangu|error)|network\s*(?:error|is unreachable)|failed to fetch|fetch failed|dioexception|errnoexception|errno\s*\d+|winerror|10054|10060|10061|11001|ssl|tls|certificate|连接超时|连接被|网络异常|握手|无法连接|拒绝连接|重置连接|域名解析|主机.*失败/i.test(m)
    }
    /**
     * 域名故障转移包装器: 逐个候选主机执行, 遇到网络层错误自动切换;
     * 候选全部失败时强制重新发现一次官方域名; 210风控等业务错误直接上抛
     */
    async withApiFailover(fn) {
        if (this.loadSetting('auto_track_api') === "0") {
            this._currentHost = this.loadData('_api_host')
                || this.manualApiHost
                || CopyManga.defaultApiUrl
            return await fn()
        }
        let candidates = this.apiHostCandidates()
        const tried = new Set()
        let rediscovered = false
        let lastError = null
        while (true) {
            const host = candidates.find(h => !tried.has(h))
            if (!host) {
                if (!rediscovered) {
                    rediscovered = true
                    if (this._discoverPromise) {
                        try { await this._discoverPromise } catch (e) { }
                    }
                    try { await this.discoverApiHosts(true) } catch (e) { }
                    candidates = this.apiHostCandidates()
                    continue
                }
                throw lastError || new Error("没有可用的拷贝漫画API域名")
            }
            tried.add(host)
            this._currentHost = host
            try {
                const result = await fn()
                this._rememberApiHost(host)
                return result
            } catch (e) {
                lastError = e
                if (!this._isHostError(e)) throw e
            }
        }
    }
    //============================================================
    //====修改(v1.8.0)====网页端通道 (SSR HTML + AES)
    //============================================================
    //官方 network2 接口会在 results.share 公布网页域; 以下为内置兜底
    static bootstrapWebHosts = [
        'www.copy5000.com',
        'www.copy4000.com',
        'www.copy20.com'
    ]
    static webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    _webHost = null
    get webBase() {
        return `https://${this._webHost || this.loadData('_web_host_cur') || CopyManga.bootstrapWebHosts[0]}`
    }
    webHostCandidates() {
        const list = []
        const push = (v) => {
            if (v && /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i.test(String(v)) && !list.includes(v)) list.push(v)
        }
        push(this._webHost); push(this.loadData('_web_host_cur'))
        let saved = this.loadData('_web_hosts')
        if (Array.isArray(saved)) saved.forEach(push)
        else if (saved) { try { JSON.parse(saved).forEach(push) } catch (e) { } }
        CopyManga.bootstrapWebHosts.forEach(push)
        return list
    }
    _rememberWebHost(host) {
        this._webHost = host
        try { this.saveData('_web_host_cur', host) } catch (e) { }
    }
    webHeaders(refererPath) {
        const h = {
            "User-Agent": CopyManga.webUA,
            "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,zh-TW;q=0.8",
        }
        if (refererPath) h["Referer"] = `${this.webBase}${refererPath}`
        const cookie = this.loadSetting('web_cookie')
        if (cookie) h["Cookie"] = cookie
        return h
    }
    /**
     * 网页主机故障转移: fn 内通过 this.webBase 取当前主机,
     * 网络层错误/403/非预期响应时切换下一个镜像
     */
    async withWebFailover(fn) {
        const hosts = this.webHostCandidates()
        const tried = new Set()
        let lastError = null
        for (const host of hosts) {
            tried.add(host)
            this._webHost = host
            try {
                const result = await fn(host)
                this._rememberWebHost(host)
                return result
            } catch (e) {
                lastError = e
                const m = String((e && e.message) || e || "")
                const okToSwitch = this._isHostError(e)
                    || /HTTP\s*(?:403|429|5\d\d)|cloudflare|非JSON|网页端返回异常/.test(m)
                if (!okToSwitch) throw e
            }
        }
        throw lastError || new Error("没有可用的拷贝漫画网页域名")
    }
    async webGet(path, refererPath, extraHeaders) {
        const res = await Network.get(`${this.webBase}${path}`,
            Object.assign(this.webHeaders(refererPath), extraHeaders || {}))
        if (res.status !== 200) {
            throw new Error(`网页端请求失败: HTTP ${res.status}`)
        }
        return res
    }
    //---- HTML 工具 ----
    static _entityMap = {
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"',
        "&#x27;": "'", "&#39;": "'", "&nbsp;": " ", "&#x2F;": "/"
    }
    htmlDecode(s) {
        if (!s) return ""
        return s.replace(/&#x27;|&#39;|&amp;|&lt;|&gt;|&quot;|&nbsp;|&#x2F;/g,
            (m) => (CopyManga._entityMap[m] !== undefined ? CopyManga._entityMap[m] : m))
    }
    stripTags(s) {
        return this.htmlDecode(String(s || "").replace(/<[^>]*>/g, "")).trim()
    }
    //解析 /comics 列表页 exemptComic-box 的 list 属性(单引号 JS 对象字面量)
    parseWebComicList(html) {
        const m = html.match(/class="[^"]*exemptComic-box[^"]*"\s+total="(\d+)"\s+list="([\s\S]*?)"\s*>/i)
        if (!m) return { list: [], total: 0 }
        const total = parseInt(m[1]) || 0
        const raw = this.htmlDecode(m[2])
        const comics = []
        const blocks = raw.split("{'path_word':").slice(1)
        for (const blk of blocks) {
            const g = (key) => {
                const mm = blk.match(new RegExp("'" + key + "':\\s*'((?:[^'\\\\]|\\\\.)*)'"))
                return mm ? mm[1] : ""
            }
            const id = g("path_word"), name = g("name"), cover = g("cover")
            if (!id) continue
            const authors = []
            const am = blk.match(/'author':\s*\[([\s\S]*?)\]/)
            if (am) {
                const re = /'name':\s*'((?:[^'\\]|\\.)*)'/g
                let mm2
                while ((mm2 = re.exec(am[1])) !== null) authors.push(mm2[1])
            }
            comics.push({
                id: id, title: name, subTitle: authors[0] || null,
                cover: cover, tags: [], description: null
            })
        }
        return { list: comics, total: total }
    }
    //解析 /rank 排行榜页
    parseWebRank(html) {
        const comics = []
        const blocks = html.match(/<li class="col-4">[\s\S]*?<\/li>/g) || []
        for (const b of blocks) {
            const sm = b.match(/href="\/comic\/([A-Za-z0-9_\-]+)"/)
            const cm = b.match(/data-src="([^"]+)"/)
            const tm = b.match(/(?:title|threeLines)"[^>]*>([^<]+)</)
                || b.match(/title="([^"]+)"[\s\S]*?threeLines/)
            const am = b.match(/作者：[\s\S]*?<a[^>]*>([^<]+)<\/a>/)
            const pm = b.match(/flameIcon[^<]*<\/span>([\d.]+W?)/)
            if (!sm) continue
            comics.push({
                id: sm[1],
                title: tm ? this.stripTags(tm[1]) : "",
                subTitle: am ? this.stripTags(am[1]) : null,
                cover: cm ? cm[1] : null,
                tags: [],
                description: pm ? "🔥" + pm[1] : null
            })
        }
        return comics
    }
    //解析详情页
    parseWebDetail(slug, html) {
        const pick = (re) => { const m = html.match(re); return m ? m[1] : null }
        const title = pick(/<h6[^>]*title="([^"]*)"/)
            || pick(/<h6[^>]*>([\s\S]*?)<\/h6>/)
        const cover = pick(/comicParticulars-left-img[\s\S]*?data-src="([^"]+)"/)
        const alias = pick(/別名：[\s\S]*?<p[^>]*>([\s\S]*?)<\/p>/)
        const authors = []
        const are = /href="\/author\/[^"]+"[^>]*>([^<]+)<\/a>/g
        let mm
        while ((mm = are.exec(html)) !== null) authors.push(this.stripTags(mm[1]))
        const tags = []
        const tre = /\/comics\?theme=[a-zA-Z0-9_]+"[^>]*>\s*#?([^<]+)</g
        while ((mm = tre.exec(html)) !== null) tags.push(this.stripTags(mm[1]))
        const updated = pick(/最後更新：[\s\S]*?comicParticulars-right-txt">\s*([0-9\-]+)/)
        const status = pick(/狀態：[\s\S]*?comicParticulars-right-txt">\s*([^<\s]+)/)
        const intro = pick(/<p class="intro"[^>]*>([\s\S]*?)<\/p>/)
        const dnt = pick(/id="dnt"[^>]*value="([^"]*)"/)
        const ccz = pick(/var\s+ccz\s*=\s*'([^']*)'/)
        const uuid = pick(/onclick="collect\('([0-9a-fA-F-]{36})'\)/)
        const chapLinks = []
        const cre = new RegExp("/comic/" + slug.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
            + "/chapter/([0-9a-fA-F-]{36})", "g")
        while ((mm = cre.exec(html)) !== null) {
            if (!chapLinks.includes(mm[1])) chapLinks.push(mm[1])
        }
        return {
            title: title ? this.htmlDecode(title).trim() : slug,
            cover: cover,
            alias: alias ? this.stripTags(alias) : "",
            authors: authors,
            tags: tags,
            updated: updated || "",
            status: status || "",
            description: intro ? this.stripTags(intro) : "",
            dnt: dnt || "3",
            ccz: ccz,
            uuid: uuid,
            chapterHints: chapLinks
        }
    }
    //网页端搜索 (明文 JSON, 无需签名)
    async webSearch(keyword, options, page) {
        const qType = (options && options[0]) || ""
        let isAuthor = false, authorPw = null
        if (keyword.startsWith("作者:")) {
            isAuthor = true
            authorPw = keyword.substring("作者:".length).trim()
        }
        const limit = 30
        const offset = (page - 1) * limit
        return await this.withWebFailover(async () => {
            let list, total
            if (isAuthor) {
                //作者主页搜索走 /comics 不支持, 直接用搜索接口的 author 模式
                const q = encodeURIComponent(authorPw)
                const res = await this.webGet(
                    `/api/kb/web/searchci/comics?limit=${limit}&offset=${offset}&q=${q}&q_type=author`,
                    "/search")
                const d = JSON.parse(res.body)
                list = (d.results && d.results.list) || []
                total = (d.results && d.results.total) || 0
            } else {
                const q = encodeURIComponent(keyword)
                const res = await this.webGet(
                    `/api/kb/web/searchci/comics?limit=${limit}&offset=${offset}&q=${q}&q_type=${qType}`,
                    "/search")
                const d = JSON.parse(res.body)
                if (!d.results || !Array.isArray(d.results.list)) {
                    throw new Error("网页端搜索返回异常")
                }
                list = d.results.list
                total = d.results.total || 0
            }
            const comics = list.map(c => ({
                id: c.path_word,
                title: c.name,
                subTitle: Array.isArray(c.author) && c.author[0] ? c.author[0].name : null,
                cover: c.cover,
                tags: Array.isArray(c.theme) ? c.theme.map(t =>
                    typeof t === "string" ? t : (t && t.name)).filter(x => x) : [],
                description: c.popular ? "🔥" + (c.popular / 10000).toFixed(1) + "W" : null
            }))
            return { comics: comics, maxPage: Math.max(1, Math.ceil(total / limit)) }
        })
    }
    //网页端分类/排行
    async webCategoryComics(category, param, options, page) {
        const limit = 50
        return await this.withWebFailover(async () => {
            if (category === "排行" || param === "ranking") {
                const aud = options[0] || "0"
                const tbl = options[1] || "day"
                const type = aud === "2" ? "female" : "male"
                const res = await this.webGet(`/rank?type=${type}&table=${tbl}`, "/rank")
                return { comics: this.parseWebRank(res.body), maxPage: 1 }
            }
            const theme = (category && CopyManga.category_param_dict[category]) || param || ""
            const ordering = (options && options[1]) || "-datetime_updated"
            const offset = (page - 1) * limit
            let path = `/comics?ordering=${encodeURIComponent(ordering)}&offset=${offset}&limit=${limit}`
            if (theme) path += `&theme=${encodeURIComponent(theme)}`
            const res = await this.webGet(path, "/comics")
            const parsed = this.parseWebComicList(res.body)
            if (!parsed.list.length) throw new Error("网页端分类返回异常")
            return {
                comics: parsed.list,
                maxPage: Math.max(1, Math.ceil(parsed.total / limit))
            }
        })
    }
    //网页端首页 (轮播推荐 + 每日推荐 + 男/女频 日/周/月/总榜)
    async webExplore() {
        return await this.withWebFailover(async (host) => {
            const result = {}
            //排行榜并行
            const boards = [
                ["男頻日榜", "male", "day"], ["男頻周榜", "male", "week"],
                ["男頻月榜", "male", "month"], ["男頻總榜", "male", "total"],
                ["女頻日榜", "female", "day"], ["女頻周榜", "female", "week"],
                ["女頻月榜", "female", "month"], ["女頻總榜", "female", "total"],
            ]
            const settled = await Promise.all(boards.map(async ([t, type, table]) => {
                try {
                    const r = await this.webGet(`/rank?type=${type}&table=${table}`, "/rank")
                    return [t, this.parseWebRank(r.body).slice(0, 20)]
                } catch (e) { return [t, []] }
            }))
            for (const [t, list] of settled) {
                if (list.length) result[t] = list
            }
            //首页轮播
            try {
                const home = await this.webGet("/", "/")
                const slides = []
                const sre = /carousel-item[\s\S]*?href="\/comic\/([^"]+)"[\s\S]*?data-src="([^"]+)"[\s\S]*?<p>([^<]*)<\/p>/g
                let mm2
                while ((mm2 = sre.exec(home.body)) !== null) {
                    if (!slides.find(x => x.id === mm2[1])) {
                        slides.push({
                            id: mm2[1], cover: mm2[2],
                            title: this.stripTags(mm2[3]), subTitle: null, tags: []
                        })
                    }
                }
                if (slides.length) result["首頁推薦"] = slides
                //每日推荐
                const daily = []
                const dre = /dailyRecommendation-img[\s\S]*?href="\/comic\/([^"]+)"[\s\S]*?data-src="([^"]+)"[\s\S]*?dailyRecommendation-txt"[^>]*title="([^"]*)"/g
                while ((mm2 = dre.exec(home.body)) !== null) {
                    daily.push({ id: mm2[1], cover: mm2[2], title: this.stripTags(mm2[3]),
                        subTitle: null, tags: [] })
                }
                if (daily.length) result["每日推薦"] = daily
            } catch (e) { }
            if (!Object.keys(result).length) throw new Error("网页端首页解析失败")
            return result
        })
    }
    //网页端详情(含完整章节列表)
    async webLoadInfo(slug) {
        return await this.withWebFailover(async () => {
            const res = await this.webGet(`/comic/${slug}`, "/comics")
            const d = this.parseWebDetail(slug, res.body)
            if (!d.ccz) throw new Error("网页端详情解析失败(密钥缺失)")
            //章节密文接口
            let chapterGroups = new Map()
            try {
                const cr = await this.webGet(`/comicdetail/${slug}/chapters`,
                    `/comic/${slug}`, { "dnts": d.dnt, "X-Requested-With": "XMLHttpRequest" })
                let payload
                try { payload = JSON.parse(cr.body).results } catch (e) {
                    throw new Error("章节接口返回非JSON")
                }
                if (typeof payload !== "string" || payload.length < 32) {
                    throw new Error("章节密文异常")
                }
                const decrypted = JSON.parse(CopyAES.decryptPayload(d.ccz, payload))
                const groups = decrypted.groups || {}
                for (const gk of Object.keys(groups)) {
                    const g = groups[gk]
                    const m = new Map()
                    for (const ch of (g.chapters || [])) {
                        m.set(ch.id, ch.name || ch.id)
                    }
                    chapterGroups.set(g.name || gk, m)
                }
            } catch (e) {
                //章节接口失败时, 至少把详情页暴露的最新话放入, 保证可以打开阅读
                console.log("网页端章节列表失败，使用详情页兜底: " + e)
                if (d.chapterHints.length) {
                    const m = new Map()
                    d.chapterHints.forEach((id, i) => m.set(id, i === 0 ? "最新話" : id))
                    chapterGroups.set("默認", m)
                } else {
                    throw e
                }
            }
            return {
                title: d.title,
                cover: d.cover,
                description: d.description + (d.alias ? `\n別名: ${d.alias}` : ""),
                tags: {
                    "作者": d.authors,
                    "更新": d.updated ? [d.updated] : [],
                    "标签": d.tags,
                    "状态": d.status ? [d.status] : [],
                },
                chapters: chapterGroups,
                isFavorite: false,
                subId: d.uuid || ""
            }
        })
    }
    //网页端阅读器
    async webLoadEp(slug, epId) {
        return await this.withWebFailover(async () => {
            const res = await this.webGet(`/comic/${slug}/chapter/${epId}`, `/comic/${slug}`)
            const html = res.body
            const cctM = html.match(/var\s+cct\s*=\s*'([^']*)'/)
            const keyM = html.match(/contentKey\s*=\s*'([^']*)'/)
            if (!cctM || !keyM) throw new Error("阅读页解析失败(密文缺失)")
            const plain = CopyAES.decryptPayload(cctM[1], keyM[1])
            const arr = JSON.parse(plain)
            if (!Array.isArray(arr) || !arr.length) throw new Error("阅读页解密无图片")
            return { images: arr.map(x => (x && x.url) || x) }
        })
    }
    //---- 双通道调度 ----
    //App v3 接口对匿名用户软封禁(200+results:null), 一旦探测到即标记, 后续走网页端
    _channelChecked = false
    _appDead = false
    markAppDead() {
        this._appDead = true
        this._channelChecked = true
        try { this.saveData("_app_dead_until", String(Date.now() + 12 * 3600 * 1000)) } catch (e) { }
    }
    async ensureChannel() {
        const mode = this.loadSetting('channel_mode') || 'auto'
        if (mode !== 'auto' || this._channelChecked) return
        const until = parseInt(this.loadData("_app_dead_until") || "0")
        if (until && Date.now() < until) {
            this._appDead = true
            this._channelChecked = true
            return
        }
        this._channelChecked = true
        try {
            const r = await Network.get(`${this.apiUrl}/api/v3/h5/homeIndex`, this.headers)
            if (r.status === 210) { this.markAppDead(); return }
            if (r.status !== 200) { this.markAppDead(); return }
            const d = JSON.parse(r.body)
            if (!d || !d.results ||
                !(d.results.recComics && d.results.recComics.list &&
                    d.results.recComics.list.length)) {
                this.markAppDead()
            }
        } catch (e) {
            //网络问题不算 App 死亡, 让各入口自行故障转移
            this._channelChecked = false
        }
    }
    async viaChannel(appFn, webFn) {
        const mode = this.loadSetting('channel_mode') || 'auto'
        if (mode === 'web' || this.loadSetting('channel_mode') === "web_only") return await webFn()
        await this.ensureChannel()
        if (mode === 'app') return await appFn()
        // auto
        if (this._appDead) return await webFn()
        try {
            return await appFn()
        } catch (e) {
            const m = String((e && e.message) || e || "")
            if (/软风控|风控|210/.test(m)) {
                this.markAppDead()
                return await webFn()
            }
            if (this._isHostError(e)) {
                //App 域名层全挂时, 尝试网页端
                try { return await webFn() } catch (e2) { throw e }
            }
            throw e
        }
    }
    //动态拉取网页端题材表, 更新分类面板
    async refreshWebThemes() {
        try {
            const res = await this.withWebFailover(() =>
                this.webGet("/filter", "/comics"))
            const pairs = []
            const seen = new Set()
            const re = /\/comics\?theme=([a-zA-Z0-9_]+)"[^>]*>\s*#?([^<]+)</g
            let mm
            while ((mm = re.exec(res.body)) !== null) {
                const param = mm[1]
                const label = this.stripTags(mm[2])
                if (param && label && !seen.has(param)) {
                    seen.add(param)
                    pairs.push([label, param])
                }
            }
            if (pairs.length) {
                this._webThemes = pairs
                this.saveData("_web_themes", JSON.stringify(pairs))
                this.category = {
                    title: "拷贝漫画",
                    parts: [
                        {
                            name: "拷贝漫画", type: "fixed",
                            categories: ["排行"], categoryParams: ["ranking"],
                            itemType: "category"
                        },
                        {
                            name: "主题", type: "fixed",
                            categories: pairs.map(p => p[0]),
                            categoryParams: pairs.map(p => p[1]),
                            itemType: "category"
                        }
                    ]
                }
            }
        } catch (e) { }
    }
    //====结束(v1.8.0)====

    get copyRegion() {
        return this.loadSetting('region') || this.defaultCopyRegion
    }
    get imageQuality() {
        return this.loadSetting('image_quality') || this.defaultImageQuality
    }
    init() {
        this.author_path_word_dict = {}
        const savedSearch = this.loadData("_search_api")
        if (savedSearch) {
            CopyManga.searchApi = savedSearch
        }
        //====修改(v1.8.0)====恢复缓存的网页端题材表(先让分类面板立即可用)
        try {
            const cached = this.loadData("_web_themes")
            const pairs = Array.isArray(cached) ? cached
                : (cached ? JSON.parse(cached) : null)
            if (Array.isArray(pairs) && pairs.length) {
                this._webThemes = pairs
                this.category = {
                    title: "拷贝漫画",
                    parts: [
                        {
                            name: "拷贝漫画", type: "fixed",
                            categories: ["排行"], categoryParams: ["ranking"],
                            itemType: "category"
                        },
                        {
                            name: "主题", type: "fixed",
                            categories: pairs.map(p => p[0]),
                            categoryParams: pairs.map(p => p[1]),
                            itemType: "category"
                        }
                    ]
                }
            }
        } catch (e) { }
        //====结束修改====
        //后台发现当前官方域名, 不阻塞源加载; 首次请求时故障转移包装器会等待它
        this._discoverPromise = this.discoverApiHosts().catch(() => { })
        this.refreshSearchApi().catch(() => { })
        //后台刷新网页端题材表
        this.refreshWebThemes().catch(() => { })
    }
    //====结束修改====
    /// account
    account = {
        login: async (account, pwd) => {
            let salt = Math.floor(1000 + Math.random() * 9000);
            let base64 = Convert.encodeBase64(Convert.encodeUtf8(`${pwd}-${salt}`))
            await this.throttle();
            let res = await Network.post(
                `${this.apiUrl}/api/v3/login`,
                {
                    ...this.headers,
                    "Content-Type": "application/x-www-form-urlencoded;charset=utf-8"
                },
                `username=${account}&password=${base64}\n&salt=${salt}&authorization=Token+`
            );
            if (res.status === 200) {
                let data = JSON.parse(res.body)
                let token = data.results.token
                this.saveData('token', token)
                return "ok"
            } else {
                throw `Invalid Status Code ${res.status}`
            }
        },
        logout: () => {
            this.deleteData('token')
        },
        registerWebsite: null
    }
    /// explore pages
    explore = [
        {
            title: "拷贝漫画",
            type: "singlePageWithMultiPart",
            load: async () => {
                //====修改(v1.8.0)====双通道: App 优先, 软封禁自动转网页端
                return await this.viaChannel(async () => {
                return await this.withApiFailover(async () => {
                //====修改====首页软风控(200+results:null): 重置指纹+等待后重试1次
                let data = null;
                for (let attempt = 0; attempt < 2; attempt++) {
                    await this.throttle();
                    let dataStr = await Network.get(
                        `${this.apiUrl}/api/v3/h5/homeIndex`,
                        this.headers
                    )
                    if (dataStr.status === 210) {
                        throw "210：访问过于频繁，已被官方风控限制，请等待1小时、切换海外线路或尝试点击设置里的“重置设备指纹池”";
                    }
                    if (dataStr.status !== 200) {
                        throw `Invalid status code: ${dataStr.status}`
                    }
                    data = JSON.parse(dataStr.body)
                    if (data && data.results) break;
                    this.autoResetDeviceFingerprint();
                    let waitTime = 10000;
                    console.log(`首页返回空数据(软风控)，等待 ${waitTime / 1000}s 后重试`);
                    await new Promise((resolve) => setTimeout(resolve, waitTime));
                }
                if (!data || !data.results) {
                    throw "首页返回空数据(软风控)，请稍后重试或点击设置里的“重置设备指纹池”";
                }
                //====结束修改====
                function parseComic(comic) {
                    if (comic["comic"] !== null && comic["comic"] !== undefined) {
                        comic = comic["comic"]
                    }
                    let tags = []
                    if (comic["theme"] !== null && comic["theme"] !== undefined) {
                        tags = comic["theme"].map(t => t["name"])
                    }
                    let author = null
                    if (Array.isArray(comic["author"]) && comic["author"].length > 0) {
                        author = comic["author"][0]["name"]
                    }
                    return {
                        id: comic["path_word"],
                        title: comic["name"],
                        subTitle: author,
                        cover: comic["cover"],
                        tags: tags
                    }
                }
                let res = {}
                res["推荐"] = data["results"]["recComics"]["list"].map(parseComic)
                res["热门"] = data["results"]["hotComics"].map(parseComic)
                res["最新"] = data["results"]["newComics"].map(parseComic)
                res["完结"] = data["results"]["finishComics"]["list"].map(parseComic)
                res["今日排行"] = data["results"]["rankDayComics"]["list"].map(parseComic)
                res["本周排行"] = data["results"]["rankWeekComics"]["list"].map(parseComic)
                res["本月排行"] = data["results"]["rankMonthComics"]["list"].map(parseComic)
                return res
                });
                }, () => this.webExplore())
            }
        }
    ]
    static category_param_dict = {
        "全部": "",
        "愛情": "aiqing",
        "歡樂向": "huanlexiang",
        "冒險": "maoxian",
        "奇幻": "qihuan",
        "百合": "baihe",
        "校园": "xiaoyuan",
        "科幻": "kehuan",
        "東方": "dongfang",
        "耽美": "danmei",
        "生活": "shenghuo",
        "格鬥": "gedou",
        "轻小说": "qingxiaoshuo",
        "悬疑": "xuanyi",
        "其他": "qita",
        "神鬼": "shengui",
        "职场": "zhichang",
        "TL": "teenslove",
        "萌系": "mengxi",
        "治愈": "zhiyu",
        "長條": "changtiao",
        "四格": "sige",
        "节操": "jiecao",
        "舰娘": "jianniang",
        "竞技": "jingji",
        "搞笑": "gaoxiao",
        "伪娘": "weiniang",
        "热血": "rexue",
        "励志": "lizhi",
        "性转换": "xingzhuanhuan",
        "彩色": "COLOR",
        "後宮": "hougong",
        "美食": "meishi",
        "侦探": "zhentan",
        "AA": "aa",
        "音乐舞蹈": "yinyuewudao",
        "魔幻": "mohuan",
        "战争": "zhanzheng",
        "历史": "lishi",
        "异世界": "yishijie",
        "惊悚": "jingsong",
        "机战": "jizhan",
        "都市": "dushi",
        "穿越": "chuanyue",
        "恐怖": "kongbu",
        "C100": "comiket100",
        "重生": "chongsheng",
        "C99": "comiket99",
        "C101": "comiket101",
        "C97": "comiket97",
        "C96": "comiket96",
        "生存": "shengcun",
        "宅系": "zhaixi",
        "武侠": "wuxia",
        "C98": "C98",
        "C95": "comiket95",
        "FATE": "fate",
        "转生": "zhuansheng",
        "無修正": "Uncensored",
        "仙侠": "xianxia",
        "LoveLive": "loveLive"
    }
    category = {
        title: "拷贝漫画",
        parts: [
            {
                name: "拷贝漫画",
                type: "fixed",
                categories: ["排行"],
                categoryParams: ["ranking"],
                itemType: "category"
            },
            {
                name: "主题",
                type: "fixed",
                categories: Object.keys(CopyManga.category_param_dict),
                categoryParams: Object.values(CopyManga.category_param_dict),
                itemType: "category"
            }
        ]
    }
    categoryComics = {
        load: async (category, param, options, page) => {
            //====修改(v1.8.0)====双通道
            return await this.viaChannel(async () => {
            return await this.withApiFailover(async () => {
            let category_url;
            if (category === "排行" || param === "ranking") {
                category_url = `${this.apiUrl}/api/v3/ranks?limit=30&offset=${(page - 1) * 30}&_update=true&type=1&audience_type=${options[0]}&date_type=${options[1]}`
            } else {
                if (category !== undefined && category !== null) {
                    param = CopyManga.category_param_dict[category] || "";
                }
                options = options.map(e => e.replace("*", "-"))
                category_url = `${this.apiUrl}/api/v3/comics?limit=30&offset=${(page - 1) * 30}&ordering=${options[1]}&theme=${param}&top=${options[0]}`
            }
            await this.throttle();
            let res = await Network.get(
                category_url,
                this.headers
            )
            if (res.status === 210) {
                throw "210：访问过于频繁，已被官方风控限制，请等待1小时、切换海外线路或尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`
            }
            let data = JSON.parse(res.body)
            if (!data || !data.results || !Array.isArray(data.results.list)) {
                throw "分类列表返回空数据(软风控)，请稍后重试";
            }
            function parseComic(comic) {
                let sort = null
                let popular = 0
                let rise_sort = 0;
                if (comic["sort"] !== null && comic["sort"] !== undefined) {
                    sort = comic["sort"]
                    rise_sort = comic["rise_sort"]
                    popular = comic["popular"]
                }
                if (comic["comic"] !== null && comic["comic"] !== undefined) {
                    comic = comic["comic"]
                }
                let tags = []
                if (comic["theme"] !== null && comic["theme"] !== undefined) {
                    tags = comic["theme"].map(t => t["name"])
                }
                let author = null
                let author_num = 0
                if (Array.isArray(comic["author"]) && comic["author"].length > 0) {
                    author = comic["author"][0]["name"]
                    author_num = comic["author"].length
                }
                if (sort !== null) {
                    return {
                        id: comic["path_word"],
                        title: comic["name"],
                        subTitle: author,
                        cover: comic["cover"],
                        tags: tags,
                        description: `${sort} ${rise_sort > 0 ? '▲' : rise_sort < 0 ? '▽' : '-'}\n` +
                            `${author_num > 1 ? `${author} 等${author_num}位` : author}\n` +
                            `🔥${(popular / 10000).toFixed(1)}W`
                    }
                } else {
                    return {
                        id: comic["path_word"],
                        title: comic["name"],
                        subTitle: author,
                        cover: comic["cover"],
                        tags: tags,
                        description: comic["datetime_updated"]
                    }
                }
            }
            return {
                comics: data["results"]["list"].map(parseComic),
                maxPage: (data["results"]["total"] - (data["results"]["total"] % 21)) / 21 + 1
            }
            });
            }, () => this.webCategoryComics(category, param, options, page))
        },
        optionList: [
            {
                options: [
                    "-全部",
                    "japan-日漫",
                    "korea-韩漫",
                    "west-美漫",
                    "finish-已完结"
                ],
                notShowWhen: null,
                showWhen: Object.keys(CopyManga.category_param_dict)
            },
            {
                options: [
                    "*datetime_updated-时间倒序",
                    "datetime_updated-时间正序",
                    "*popular-热度倒序",
                    "popular-热度正序",
                ],
                notShowWhen: null,
                showWhen: Object.keys(CopyManga.category_param_dict)
            },
            {
                options: [
                    "0-全部",
                    "1-男性向",
                    "2-女性向"
                ],
                notShowWhen: null,
                showWhen: ["排行"]
            },
            {
                options: [
                    "day-日榜",
                    "week-周榜",
                    "month-月榜",
                    "total-總榜(网页端)"
                ],
                notShowWhen: null,
                showWhen: ["排行"]
            }
        ]
    }
    search = {
        load: async (keyword, options, page) => {
            //====修改(v1.8.0)====双通道
            return await this.viaChannel(async () => {
            return await this.withApiFailover(async () => {
            let author;
            if (keyword.startsWith("作者:")) {
                author = keyword.substring("作者:".length).trim();
            }
            let res;
            await this.throttle();
            if (author && author in this.author_path_word_dict) {
                let path_word = encodeURIComponent(this.author_path_word_dict[author]);
                res = await Network.get(
                    `${this.apiUrl}/api/v3/comics?limit=30&offset=${(page - 1) * 30}&ordering=-datetime_updated&author=${path_word}`,
                    this.headers
                )
            } else {
                let q_type = "";
                if (options && options[0]) {
                    q_type = options[0];
                }
                keyword = encodeURIComponent(keyword)
                let search_url = this.loadSetting('search_api') === "webAPI"
                    ? `${this.apiUrl}${CopyManga.searchApi}`
                    : `${this.apiUrl}/api/v3/search/comic`
                res = await Network.get(
                    `${search_url}?limit=30&offset=${(page - 1) * 30}&q=${keyword}&q_type=${q_type}`,
                    this.headers
                )
            }
            if (res.status === 210) {
                throw "210：访问过于频繁，已被官方风控限制，请等待1小时、切换海外线路或尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`
            }
            let data = JSON.parse(res.body)
            if (!data || !data.results || !Array.isArray(data.results.list)) {
                throw "搜索返回空数据(软风控)，请稍后重试";
            }
            function parseComic(comic) {
                if (comic["comic"] !== null && comic["comic"] !== undefined) {
                    comic = comic["comic"]
                }
                let tags = []
                if (comic["theme"] !== null && comic["theme"] !== undefined) {
                    tags = comic["theme"].map(t => t["name"])
                }
                let author = null
                if (Array.isArray(comic["author"]) && comic["author"].length > 0) {
                    author = comic["author"][0]["name"]
                }
                return {
                    id: comic["path_word"],
                    title: comic["name"],
                    subTitle: author,
                    cover: comic["cover"],
                    tags: tags,
                    description: comic["datetime_updated"]
                }
            }
            return {
                comics: data["results"]["list"].map(parseComic),
                maxPage: (data["results"]["total"] - (data["results"]["total"] % 21)) / 21 + 1
            }
            });
            }, () => this.webSearch(keyword, options, page))
        },
        optionList: [
            {
                type: "select",
                options: [
                    "-全部",
                    "name-名称",
                    "author-作者",
                    "local-汉化组"
                ],
                label: "搜索选项"
            }
        ]
    }
    favorites = {
        multiFolder: false,
        addOrDelFavorite: async (comicId, folderId, isAdding) => {
            let is_collect = isAdding ? 1 : 0
            let token = this.loadData("token");
            let reqId = await this.getReqID();
            await this.throttle();
            let comicData = await Network.get(
                `${this.apiUrl}/api/v3/comic2/${comicId}?in_mainland=true&request_id=${reqId}&platform=3`,
                this.headers
            )
            if (comicData.status === 210) {
                throw "210：访问过于频繁，已被官方风控限制，请等待1小时、切换海外线路或尝试点击设置里的“重置设备指纹池”";
            }
            if (comicData.status !== 200) {
                throw `Invalid status code: ${comicData.status}`
            }
            let comic_id = JSON.parse(comicData.body).results.comic.uuid
            await this.throttle();
            let res = await Network.post(
                `${this.apiUrl}/api/v3/member/collect/comic`,
                {
                    ...this.headers,
                    "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                },
                `comic_id=${comic_id}&is_collect=${is_collect}&authorization=Token+${token}`
            )
            if (res.status === 401) {
                throw `Login expired`;
            }
            if (res.status === 210) {
                throw "210：操作过于频繁，已被官方风控限制，请等待1小时、切换海外线路或尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`
            }
            return "ok"
        },
        loadComics: async (page, folder) => {
            //====修改(v1.7.0)====域名故障转移包装
            return await this.withApiFailover(async () => {
            let ordering = this.loadSetting('favorites_ordering') || '-datetime_updated';
            await this.throttle();
            var res = await Network.get(
                `${this.apiUrl}/api/v3/member/collect/comics?limit=30&offset=${(page - 1) * 30}&free_type=1&ordering=${ordering}`,
                this.headers
            )
            if (res.status === 401) {
                throw `Login expired`
            }
            if (res.status === 210) {
                throw "210：访问过于频繁，已被官方风控限制，请等待1小时、切换海外线路或尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`
            }
            let data = JSON.parse(res.body)
            function parseComic(comic) {
                if (comic["comic"] !== null && comic["comic"] !== undefined) {
                    comic = comic["comic"]
                }
                let tags = []
                if (comic["theme"] !== null && comic["theme"] !== undefined) {
                    tags = comic["theme"].map(t => t["name"])
                }
                let author = null
                if (Array.isArray(comic["author"]) && comic["author"].length > 0) {
                    author = comic["author"][0]["name"]
                }
                return {
                    id: comic["path_word"],
                    title: comic["name"],
                    subTitle: author,
                    cover: comic["cover"],
                    tags: tags,
                    description: comic["datetime_updated"]
                }
            }
            return {
                comics: data["results"]["list"].map(parseComic),
                maxPage: (data["results"]["total"] - (data["results"]["total"] % 21)) / 21 + 1
            }
            });
        }
    }
    comic = {
        loadInfo: async (id) => {
            //====修改(v1.8.0)====双通道
            return await this.viaChannel(async () => {
            return await this.withApiFailover(async () => {
            let getChapters = async (id, groups) => {
                let fetchSingle = async (id, path) => {
                    let reqId = await this.getReqID();
                    await this.throttle();
                    let res = await Network.get(
                        `${this.apiUrl}/api/v3/comic/${id}/group/${path}/chapters?limit=100&offset=0&in_mainland=true&request_id=${reqId}`,
                        this.headers
                    );
                    if (res.status === 210) {
                        throw "210：章节列表访问过于频繁，已被官方风控限制，请尝试切换海外线路或点击设置里的“重置设备指纹池”";
                    }
                    if (res.status !== 200) {
                        throw `Invalid status code: ${res.status}`;
                    }
                    let data = JSON.parse(res.body);
                    let eps = new Map();
                    data.results.list.forEach((e) => {
                        let title = e.name;
                        let id = e.uuid;
                        eps.set(id, title);
                    });
                    let maxChapter = data.results.total;
                    if (maxChapter > 100) {
                        let offset = 100;
                        while (offset < maxChapter) {
                            await this.throttle();
                            res = await Network.get(
                                `${this.apiUrl}/api/v3/comic/${id}/group/${path}/chapters?limit=100&offset=${offset}`,
                                this.headers
                            );
                            if (res.status === 210) {
                                throw "210：章节列表访问过于频繁，已被官方风控限制，请尝试切换海外线路或点击设置里的“重置设备指纹池”";
                            }
                            if (res.status !== 200) {
                                throw `Invalid status code: ${res.status}`;
                            }
                            data = JSON.parse(res.body);
                            data.results.list.forEach((e) => {
                                let title = e.name;
                                let id = e.uuid;
                                eps.set(id, title)
                            });
                            offset += 100;
                        }
                    }
                    return eps;
                };
                let keys = Object.keys(groups);
                let result = {};
                let futures = [];
                for (let group of keys) {
                    let path = groups[group]["path_word"];
                    futures.push((async () => {
                        result[group] = await fetchSingle(id, path);
                    })());
                }
                await Promise.all(futures);
                if (this.isAppVersionAfter("1.3.0")) {
                    let sortedResult = new Map();
                    for (let key of keys) {
                        let name = groups[key]["name"];
                        sortedResult.set(name, result[key]);
                    }
                    return sortedResult;
                } else {
                    let merged = new Map();
                    for (let key of keys) {
                        for (let [k, v] of result[key]) {
                            merged.set(k, v);
                        }
                    }
                    return merged;
                }
            }
            let getFavoriteStatus = async (id) => {
                await this.throttle();
                let res = await Network.get(`${this.apiUrl}/api/v3/comic2/${id}/query`, this.headers);
                if (res.status === 210) {
                    return false;
                }
                if (res.status !== 200) {
                    throw `Invalid status code: ${res.status}`;
                }
                return JSON.parse(res.body).results.collect != null;
            }
            //====修改====详情请求加重试: 硬风控210/软风控results:null都重置指纹+退避重试
            let results;
            let data = null;
            for (let attempt = 0; attempt < 3; attempt++) {
                let reqId = await this.getReqID();
                await this.throttle();
                results = await Promise.all([
                    Network.get(
                        `${this.apiUrl}/api/v3/comic2/${id}?in_mainland=true&request_id=${reqId}&platform=3`,
                        this.headers
                    ),
                    getFavoriteStatus.bind(this)(id)
                ])
                if (results[0].status === 210) {
                    // 硬风控: 记录被封指纹 + 重置 + 阶梯退避
                    this.markDeviceBlocked();
                    this.autoResetDeviceFingerprint();
                    let waitTime = 10000 + attempt * 10000;
                    console.log(`详情触发210风控，等待 ${waitTime / 1000}s 后重试 (${attempt + 1}/3)`);
                    await new Promise((resolve) => setTimeout(resolve, waitTime));
                    continue;
                }
                if (results[0].status !== 200) {
                    throw `Invalid status code: ${results[0].status}`;
                }
                data = JSON.parse(results[0].body).results;
                if (!data || !data.comic) {
                    // 软风控(200+results:null): 重置指纹 + 退避重试, 不再报TypeError
                    this.autoResetDeviceFingerprint();
                    let waitTime = 10000 + attempt * 10000;
                    console.log(`详情返回空数据(软风控)，等待 ${waitTime / 1000}s 后重试 (${attempt + 1}/3)`);
                    await new Promise((resolve) => setTimeout(resolve, waitTime));
                    continue;
                }
                break;
            }
            if (!data || !data.comic) {
                throw "210：漫画详情访问过于频繁，已被官方风控限制。请稍后重试或点击设置里的“重置设备指纹池”";
            }
            let comicData = data.comic;
            //====结束修改====
            let title = comicData.name;
            let cover = comicData.cover;
            let authors = comicData.author.map(e => e.name);
            if (Object.keys(this.author_path_word_dict).length > 100) {
                this.author_path_word_dict = {};
            }
            comicData.author.forEach(e => (this.author_path_word_dict[e.name] = e.path_word));
            let tags = comicData.theme.map(e => e?.name).filter(name => name !== undefined && name !== null);
            let updateTime = comicData.datetime_updated ? comicData.datetime_updated : "";
            let description = comicData.brief;
            let chapters = await getChapters(id, data.groups);
            let status = comicData.status.display;
            return {
                title: title,
                cover: cover,
                description: description,
                tags: {
                    "作者": authors,
                    "更新": [updateTime],
                    "标签": tags,
                    "状态": [status],
                },
                chapters: chapters,
                isFavorite: results[1],
                subId: comicData.uuid
            }
            });
            }, () => this.webLoadInfo(id))
        },
        loadEp: async (comicId, epId) => {
            //====修改(v1.8.0)====双通道
            return await this.viaChannel(async () => {
            return await this.withApiFailover(async () => {
            //====修改====读取配置：是否每一章强制重置指纹
            const autoResetEveryChapter = this.loadSetting('auto_reset_finger_every_ep') === "1";
            if(autoResetEveryChapter){
                this.autoResetDeviceFingerprint();
            }
            //====结束修改====

            let attempt = 0;
            const maxAttempts = 6;
            let res;
            let data;
            while (attempt < maxAttempts) {
                try {
                    let reqId = await this.getReqID();
                    await this.throttle();
                    res = await Network.get(
                        `${this.apiUrl}/api/v3/comic/${comicId}/chapter2/${epId}?in_mainland=true&request_id=${reqId}`,
                        {
                            ...this.headers
                        }
                    );
                    if (res.status === 210) {
                        //====修改====捕获210风控，自动重置指纹再重试
                        this.markDeviceBlocked();
                        console.log(`检测到210风控，执行自动重置设备指纹`);
                        this.autoResetDeviceFingerprint();
                        //====结束修改====

                        let waitTime = 10000 + attempt * 5000; // 阶梯退避重试
                        try {
                            let responseBody = JSON.parse(res.body);
                            if (
                                responseBody.message &&
                                responseBody.message.includes("Expected available in")
                            ) {
                                let match = responseBody.message.match(/(\d+)\s*seconds/);
                                if (match && match[1]) {
                                    waitTime = parseInt(match[1]) * 1000;
                                }
                            }
                        } catch (e) {
                        }
                        console.log(`Chapter ${epId} 触发风控(210)，等待 ${waitTime / 1000}s 后重试 (${attempt + 1}/${maxAttempts})`);
                        await new Promise((resolve) => setTimeout(resolve, waitTime));
                        attempt++;
                        if (attempt >= maxAttempts) {
                            throw "210：章节内容加载频繁，已被官方风控限制。请尝试切换【海外线路】或点击设置里的“重置设备指纹池”。";
                        }
                        continue;
                    }
                    if (res.status !== 200) {
                        throw `Invalid status code: ${res.status}`;
                    }
                    data = JSON.parse(res.body);
                    if (!data.results || !data.results.chapter || !Array.isArray(data.results.chapter.contents)) {
                        //====修改====软风控(200+空章节数据): 重置指纹+退避重试, 与210同样处理
                        console.log(`检测到软风控(章节空数据)，执行自动重置设备指纹`);
                        this.autoResetDeviceFingerprint();
                        let waitTime = 10000 + attempt * 5000;
                        console.log(`Chapter ${epId} 触发软风控，等待 ${waitTime / 1000}s 后重试 (${attempt + 1}/${maxAttempts})`);
                        await new Promise((resolve) => setTimeout(resolve, waitTime));
                        attempt++;
                        if (attempt >= maxAttempts) {
                            throw "210：章节内容加载频繁，已被官方风控限制。请尝试切换【海外线路】或点击设置里的“重置设备指纹池”。";
                        }
                        continue;
                        //====结束修改====
                    }
                    let imagesUrls = data.results.chapter.contents.map((e) => e.url);
                    let orders = data.results.chapter.words;
                    let hdImagesUrls = imagesUrls.map((url) => {
                        return url.replace(/([./])c\d+x\.[a-zA-Z]+$/, `$1c${this.imageQuality}x.webp`)
                    })
                    let images = new Array(hdImagesUrls.length).fill("");
                    for (let i = 0; i < hdImagesUrls.length; i++) {
                        images[orders[i]] = hdImagesUrls[i];
                    }
                    return {
                        images: images,
                    };
                } catch (error) {
                    if (typeof error === 'string' && error.startsWith("210")) {
                        throw error;
                    }
                    //====修改(v1.7.0)====域名层故障快速上抛给外层切换, 不对同一死域重试6次
                    if (this._isHostError(error)) {
                        throw error;
                    }
                    //====结束修改====
                    attempt++;
                    if (attempt >= maxAttempts) {
                        throw error;
                    }
                    await new Promise((resolve) => setTimeout(resolve, 3000));
                }
            }
            });
            }, () => this.webLoadEp(comicId, epId))
        },
        //====新增(v1.8.0)====网页端图片防盗链头(CDN 实际宽松, 带头兜底)
        onImageLoad: (url, comicId, epId) => {
            const buildConfig = () => ({
                url: url,
                method: "GET",
                headers: {
                    "User-Agent": CopyManga.webUA,
                    "Referer": `${this.webBase}/`,
                    "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
                }
            })
            return {
                ...buildConfig(),
                onLoadFailed: () => buildConfig()
            }
        },
        onThumbnailLoad: (url) => {
            const buildConfig = () => ({
                url: url,
                method: "GET",
                headers: {
                    "User-Agent": CopyManga.webUA,
                    "Referer": `${this.webBase}/`
                }
            })
            return {
                ...buildConfig(),
                onLoadFailed: () => buildConfig()
            }
        },
        loadComments: async (comicId, subId, page, replyTo) => {
            let url = `${this.apiUrl}/api/v3/comments?comic_id=${subId}&limit=20&offset=${(page - 1) * 20}`;
            if (replyTo) {
                url = url + `&reply_id=${replyTo}&_update=true`;
            }
            await this.throttle();
            let res = await Network.get(
                url,
                this.headers,
            );
            if (res.status === 210) {
                throw "210：评论加载频繁，请尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`;
            }
            let data = JSON.parse(res.body);
            let total = data.results.total;
            return {
                comments: data.results.list.map(e => {
                    return {
                        userName: replyTo ? `${e.user_name}  👉  ${e.parent_user_name}` : e.user_name,
                        avatar: e.user_avatar,
                        content: e.comment,
                        time: e.create_at,
                        replyCount: e.count,
                        id: e.id,
                    }
                }),
                maxPage: (total - (total % 20)) / 20 + 1,
            }
        },
        sendComment: async (comicId, subId, content, replyTo) => {
            let token = this.loadData("token");
            if (!token) {
                throw "未登录"
            }
            if (!replyTo) {
                replyTo = '';
            }
            await this.throttle();
            let res = await Network.post(
                `${this.apiUrl}/api/v3/member/comment`,
                {
                    ...this.headers,
                    "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                },
                `comic_id=${subId}&comment=${encodeURIComponent(content)}&reply_id=${replyTo}`,
            );
            if (res.status === 401) {
                throw `Login expired`;
            }
            if (res.status === 210) {
                throw "210：发送评论过于频繁，请尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`;
            } else {
                return "ok"
            }
        },
        loadChapterComments: async (comicId, epId, page, replyTo) => {
            let url = `${this.apiUrl}/api/v3/roasts?chapter_id=${epId}&limit=20&offset=${(page - 1) * 20}`;
            await this.throttle();
            let res = await Network.get(
                url,
                this.headers,
            );
            if (res.status === 210) {
                throw "210：吐槽加载频繁，请尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`;
            }
            let data = JSON.parse(res.body);
            let total = data.results.total;
            return {
                comments: data.results.list.map(e => {
                    return {
                        userName: e.user_name,
                        avatar: e.user_avatar,
                        content: e.comment,
                        time: e.create_at,
                        replyCount: null,
                        id: null,
                    }
                }),
                maxPage: (total - (total % 20)) / 20 + 1,
            }
        },
        sendChapterComment: async (comicId, epId, content, replyTo) => {
            let token = this.loadData("token");
            if (!token) {
                throw "未登录"
            }
            await this.throttle();
            let res = await Network.post(
                `${this.apiUrl}/api/v3/member/roast`,
                {
                    ...this.headers,
                    "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                },
                `chapter_id=${epId}&roast=${encodeURIComponent(content)}`,
            );
            if (res.status === 401) {
                throw `Login expired`;
            }
            if (res.status === 210) {
                throw "210：评论过于频繁，请尝试点击设置里的“重置设备指纹池”";
            }
            if (res.status !== 200) {
                throw `Invalid status code: ${res.status}`;
            } else {
                return "ok"
            }
        },
        onClickTag: (namespace, tag) => {
            if (namespace === "标签") {
                return {
                    action: 'category',
                    keyword: `${tag}`,
                    param: null,
                }
            }
            if (namespace === "作者") {
                return {
                    action: 'search',
                    keyword: `${namespace}:${tag}`,
                    param: null,
                }
            }
            throw "未支持此类Tag检索"
        }
    }
    settings = {
        favorites_ordering: {
            title: "收藏排序方式",
            type: "select",
            options: [
                {
                    value: '-datetime_updated',
                    text: '更新时间'
                },
                {
                    value: '-datetime_modifier',
                    text: '收藏时间'
                },
                {
                    value: '-datetime_browse',
                    text: '阅读时间'
                }
            ],
            default: '-datetime_updated',
        },
        //====修改====新增设置项：每章节自动重置指纹开关，放在callback项之前！
        auto_reset_finger_every_ep:{
            title:"每切换章节强制重置设备指纹(谨慎开启)",
            type:"select",
            options:[
                {value:"0",text:"关闭(仅风控210才自动重置)"},
                {value:"1",text:"开启，每一章都重置指纹"}
            ],
            default:"1"
        },
        enable_virtual_ip: {
            title: "虚拟IP轮换(实验性,默认关闭)",
            type: "select",
            options: [
                {value:"0",text:"关闭(推荐，官方App不带虚拟IP)"},
                {value:"1",text:"开启，每次重置指纹同时换虚拟IP"}
            ],
            default: "0"
        },
        //====结束修改====
        //====修改(v1.7.0)====API域名自动追踪开关
        auto_track_api: {
            title: "API域名自动追踪",
            type: "select",
            options: [
                {value: "1", text: "开启(推荐): 自动检测官方最新API地址并故障转移"},
                {value: "0", text: "关闭: 仅使用下方手动填写的API地址"}
            ],
            default: "1"
        },
        //====结束修改====
        region: {
            title: "CDN线路",
            type: "select",
            options: [
                {
                    value: "0",
                    text: '海外线路 (推荐防风控)'
                },
                {
                    value: "1",
                    text: '大陆线路'
                }
            ],
            default: CopyManga.defaultCopyRegion,
        },
        image_quality: {
            title: "图片质量",
            type: "select",
            options: [
                {
                    value: '800',
                    text: '低 (800)'
                },
                {
                    value: '1200',
                    text: '中 (1200)'
                },
                {
                    value: '1500',
                    text: '高 (1500)'
                }
            ],
            default: CopyManga.defaultImageQuality,
        },
        search_api: {
            title: "搜索方式",
            type: "select",
            options: [
                {
                    value: 'baseAPI',
                    text: '基础API'
                },
                {
                    value: 'webAPI',
                    text: '网页端API'
                }
            ],
            default: 'baseAPI'
        },
        base_url: {
            title: "API地址",
            type: "input",
            validator: '^(?!:\\/\\/)(?=.{1,253})([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,}$',
            default: CopyManga.defaultApiUrl,
        },
        //====新增(v1.8.0)====数据通道选择
        channel_mode: {
            title: "数据通道 (App接口被封时自动走网页端)",
            type: "select",
            options: [
                { value: "auto", text: "自动(推荐): App优先, 检测到软封禁自动切换网页端" },
                { value: "web", text: "强制网页端: 始终使用网页版通道(HTML+解密)" },
                { value: "app", text: "强制App接口: 仅使用v3签名接口" }
            ],
            default: "auto"
        },
        web_cookie: {
            title: "网页端Cookie(可选, 登录后填写可访问账号内容)",
            type: "input",
            default: ""
        },
        //====结束新增====
        //【重要】callback类型设置必须放在settings对象的最后！！
        clear_device_info: {
            title: "重置设备指纹池",
            type: "callback",
            buttonText: "点击切换真实设备指纹",
            callback: () => {
                this.deleteData("_deviceinfo");
                this.deleteData("_device");
                this.deleteData("_pseudoid");
                this.deleteData("_virtual_ip");
                this.deleteData("_exclude_deviceinfo");
                this.deleteData("_exclude_device");
                this.deleteData("_blocked_deviceinfos");
                this.refreshAppApi();
            }
        },
        //====修改(v1.7.0)====手动立即检测最新API地址(callback必须在最后)
        refresh_api_now: {
            title: "立即检测最新API地址",
            type: "callback",
            buttonText: "检测并更新",
            callback: () => {
                this.refreshAppApi();
            }
        }
        //====结束修改====
    }
    isAppVersionAfter(target) {
        let current = APP.version
        let targetArr = target.split('.')
        let currentArr = current.split('.')
        for (let i = 0; i < 3; i++) {
            if (parseInt(currentArr[i]) < parseInt(targetArr[i])) {
                return false
            }
        }
        return true
    }
    //====修改(v1.7.0)====搜索接口路径自动追踪(沙箱无全局fetch, 改用Network.get)
    async refreshSearchApi() {
        let webHosts = []
        try {
            const saved = this.loadData('_web_hosts')
            if (saved) {
                webHosts = JSON.parse(saved)
            }
        } catch (e) { }
        const hosts = []
        webHosts.concat(CopyManga.bootstrapWebHosts).forEach(w => {
            if (w && !hosts.includes(w)) hosts.push(w)
        })
        for (const web of hosts) {
            try {
                const res = await Network.get(
                    `https://${web}/search`,
                    { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" }
                )
                if (res.status !== 200) continue
                const match = res.body.match(/const countApi = "([^"]+)"/)
                if (match && match[1]) {
                    CopyManga.searchApi = match[1]
                    this.saveData("_search_api", match[1])
                    return
                }
            } catch (e) { }
        }
    }
    //手动/重置时立即重新发现官方API域名(带签名验证, 结果持久化, 不再破坏settings结构)
    async refreshAppApi() {
        this._discoverPromise = this.discoverApiHosts(true).catch(() => { })
        await this._discoverPromise
        await this.refreshSearchApi().catch(() => { })
    }
    //====结束修改====
}
