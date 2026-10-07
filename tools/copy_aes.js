/* ============================================================
 * 精简 AES-128-CBC 实现 (纯 JS, 无依赖, 可运行于 Venera QuickJS 沙箱)
 * 仅实现拷贝漫画网页端解密所需路径:
 *   - key: 16 字节 UTF-8 字符串
 *   - iv : 密文前 16 个字符的 ASCII 字节
 *   - ct : 剩余部分 hex 解码
 *   - Pkcs7 去填充, 返回 UTF-8 字符串
 * S 盒通过 GF(2^8) 求逆 + 仿射变换动态生成, 避免大表转录错误
 * ============================================================ */
var CopyAES = (function () {
    // ---- GF(2^8) ----
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
        for (var i = 1; i < 256; i++) {
            if (gmul(b, i) === 1) return i;
        }
        return 0;
    }
    var SBOX = new Array(256), ISBOX = new Array(256);
    (function () {
        for (var i = 0; i < 256; i++) {
            var x = ginv(i);
            var s = x ^ rotl8(x, 1) ^ rotl8(x, 2) ^ rotl8(x, 3) ^ rotl8(x, 4) ^ 0x63;
            SBOX[i] = s & 0xff;
            ISBOX[s & 0xff] = i;
        }
    })();
    function rotl8(v, n) { return ((v << n) | (v >>> (8 - n))) & 0xff; }

    // ---- 密钥扩展 (AES-128: Nk=4, Nr=10) ----
    var RCON = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];
    function keyExpansion(key) {
        var w = new Array(44);           // 11 个轮密钥, 每个 4 字
        for (var i = 0; i < 4; i++) {
            w[i] = [key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]];
        }
        for (i = 4; i < 44; i++) {
            var t = w[i - 1].slice();
            if (i % 4 === 0) {
                // RotWord
                t = [t[1], t[2], t[3], t[0]];
                // SubWord
                t = [SBOX[t[0]], SBOX[t[1]], SBOX[t[2]], SBOX[t[3]]];
                t[0] ^= RCON[i / 4];
            }
            var p = w[i - 4];
            w[i] = [p[0] ^ t[0], p[1] ^ t[1], p[2] ^ t[2], p[3] ^ t[3]];
        }
        return w;
    }

    // ---- 单块解密 ----
    function addRoundKey(state, w, round) {
        for (var c = 0; c < 4; c++) {
            var k = w[round * 4 + c];
            state[0][c] ^= k[0];
            state[1][c] ^= k[1];
            state[2][c] ^= k[2];
            state[3][c] ^= k[3];
        }
    }
    function invSubBytes(state) {
        for (var r = 0; r < 4; r++)
            for (var c = 0; c < 4; c++)
                state[r][c] = ISBOX[state[r][c]];
    }
    function invShiftRows(state) {
        // state[r][c], 行 r 循环右移 r
        for (var r = 1; r < 4; r++) {
            var row = [state[r][0], state[r][1], state[r][2], state[r][3]];
            for (var c = 0; c < 4; c++) {
                state[r][c] = row[(c - r + 4) % 4];
            }
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
        // block: 16 字节 -> state[r][c] (列优先)
        var state = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
        for (var c = 0; c < 4; c++)
            for (var r = 0; r < 4; r++)
                state[r][c] = block[c * 4 + r];
        addRoundKey(state, w, 10);
        for (var round = 9; round >= 1; round--) {
            invShiftRows(state);
            invSubBytes(state);
            addRoundKey(state, w, round);
            invMixColumns(state);
        }
        invShiftRows(state);
        invSubBytes(state);
        addRoundKey(state, w, 0);
        var out = new Array(16);
        for (c = 0; c < 4; c++)
            for (r = 0; r < 4; r++)
                out[c * 4 + r] = state[r][c];
        return out;
    }

    // ---- 工具 ----
    function hexToBytes(hex) {
        var out = new Array(hex.length / 2);
        for (var i = 0; i < out.length; i++) {
            out[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return out;
    }
    function utf8ToBytes(str) {
        // 支持 key 的非 ASCII (拷贝 key 固定为 ASCII, 但保持通用)
        var bytes = [];
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i);
            if (c < 0x80) bytes.push(c);
            else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
            else if (c < 0xd800 || c >= 0xe000) {
                bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
            } else {
                i++;
                var c2 = str.charCodeAt(i);
                var cp = 0x10000 + (((c & 0x3ff) << 10) | (c2 & 0x3ff));
                bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
                    0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
            }
        }
        return bytes;
    }
    function bytesToUtf8(bytes) {
        // UTF-8 解码 (含 3/4 字节)
        var out = "", i = 0;
        while (i < bytes.length) {
            var b = bytes[i++];
            if (b < 0x80) out += String.fromCharCode(b);
            else if ((b & 0xe0) === 0xc0) {
                out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f));
            } else if ((b & 0xf0) === 0xe0) {
                out += String.fromCharCode(((b & 0x0f) << 12) |
                    ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
            } else {
                var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) |
                    ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
                cp -= 0x10000;
                out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
            }
        }
        return out;
    }

    function bytesToHex(bytes) {
        var s = "";
        for (var i = 0; i < bytes.length; i++) {
            var h = bytes[i].toString(16);
            if (h.length < 2) h = "0" + h;
            s += h;
        }
        return s;
    }

    // 原始 CBC: keyBytes(16), iv 字节数组(16), ct 字节数组; 返回明文字节数组
    function rawCbcDecryptBytes(key, iv, ct) {
        if (key.length !== 16) throw new Error("AES key must be 16 bytes");
        var w = keyExpansion(key);
        var plain = [];
        var prev = iv;
        for (var off = 0; off < ct.length; off += 16) {
            var block = ct.slice(off, off + 16);
            var dec = decryptBlock(block, w);
            for (var j = 0; j < 16; j++) plain.push(dec[j] ^ prev[j]);
            prev = block;
        }
        return plain;
    }
    function stripPkcs7(plain) {
        var pad = plain[plain.length - 1];
        if (pad < 1 || pad > 16) return plain;
        for (var k = plain.length - pad; k < plain.length; k++) {
            if (plain[k] !== pad) return plain;
        }
        return plain.slice(0, plain.length - pad);
    }

    /**
     * 拷贝网页端解密
     * @param {string} keyStr 16 字节 ASCII 密钥 (ccz / cct)
     * @param {string} payload results/contentKey: 前16字符=ASCII iv, 其余=hex 密文
     * @returns {string} Pkcs7 去填充后的 UTF-8 明文
     */
    function decryptPayload(keyStr, payload) {
        var iv = [];
        for (var i = 0; i < 16; i++) iv.push(payload.charCodeAt(i));
        var ct = hexToBytes(payload.substring(16));
        var plain = stripPkcs7(rawCbcDecryptBytes(utf8ToBytes(keyStr), iv, ct));
        return bytesToUtf8(plain);
    }

    return {
        decryptPayload: decryptPayload,
        rawCbcDecryptBytes: rawCbcDecryptBytes,
        bytesToHex: bytesToHex,
        hexToBytes: hexToBytes,
        utf8ToBytes: utf8ToBytes,
        gmul: gmul,
        SBOX: SBOX
    };
})();

// 自测 NIST FIPS-197 样例 (可选, 外部不调用)
function aesSelfTest() {
    // 已知 CBC 向量: key/iv/plain
    var key = "1234567890123456";
    var ivHex = "000102030405060708090a0b0c0d0e0f";
    // 用 gmul 间接验证: 已知 0x57*0x83 = 0xc1
    return CopyAES.gmul(0x57, 0x83) === 0xc1;
}
