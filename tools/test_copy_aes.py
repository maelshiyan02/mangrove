# -*- coding: utf-8 -*-
"""QuickJS 验证内嵌 AES: NIST SP800-38A 向量 + 拷贝真实密文样本"""
import sys, io, json, re, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import quickjs

OUT = r"d:\Ballonstranslator_Windows\probe_out"
aes_js = open(r"d:\Ballonstranslator_Windows\copy_aes.js", encoding="utf-8").read()
ctx = quickjs.Context()
ctx.eval(aes_js)

results = {}

# ---------- 1. GF 乘法 ----------
results["gmul_0x57_0x83"] = ctx.eval("CopyAES.gmul(0x57,0x83)")

# ---------- 2. S 盒抽查 (FIPS: 0x53->0xed, 0x00->0x63, 0xff->0x16) ----------
results["sbox_00"] = ctx.eval("CopyAES.SBOX[0x00]")
results["sbox_53"] = ctx.eval("CopyAES.SBOX[0x53]")
results["sbox_ff"] = ctx.eval("CopyAES.SBOX[0xff]")

# ---------- 3. NIST SP800-38A AES-128-CBC 解密向量 ----------
# key  2b7e151628aed2a6abf7158809cf4f3c
# iv   000102030405060708090a0b0c0d0e0f
# c1   7649abac8119b246cee98e9b12e9197d
# c2   5086cb9b507219ee95db113a917678b2
# p1   6bc1bee22e409f96e93d7e117393172a
# p2   ae2d8a571e03ac9c9eb76fac45af8e51
test_js = r"""
(function(){
  var key = CopyAES.hexToBytes('2b7e151628aed2a6abf7158809cf4f3c');
  var iv  = CopyAES.hexToBytes('000102030405060708090a0b0c0d0e0f');
  var ct  = CopyAES.hexToBytes('7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2');
  var pt  = CopyAES.rawCbcDecryptBytes(key, iv, ct);
  return CopyAES.bytesToHex(pt);
})()
"""
got = ctx.eval(test_js)
expected = ("6bc1bee22e409f96e93d7e117393172a"
            "ae2d8a571e03ac9c9eb76fac45af8e51")
results["nist_cbc"] = {"got": got, "ok": got == expected}

# ---------- 4. 真实章节密文 ----------
enc = open(os.path.join(OUT, "chapters_haizeiwang_enc.txt"), encoding="utf-8").read().strip()
expected_ch = json.load(open(os.path.join(OUT, "chapters_haizeiwang_dec.json"), encoding="utf-8"))
ctx.add_callable("print", lambda *a: None)
ctx.eval("var __enc=%s, __key='op0zzpvv.nmn.00p';" % json.dumps(enc))
plain = ctx.eval("CopyAES.decryptPayload(__key, __enc)")
j = json.loads(plain)
chs = j["groups"]["default"]["chapters"]
results["chapters_real"] = {
    "groups": list(j.get("groups", {}).keys()),
    "count": j["groups"]["default"]["count"],
    "chapters_len": len(chs),
    "first": chs[0], "last": chs[-1],
    "ok": len(chs) == 398 and chs[0]["id"] == "4bd05882-c7bc-11e8-881a-024352452ce0"
          and chs[-1]["id"] == "bac64faf-b23e-11f1-9fe3-fa163e02432f",
}

# ---------- 5. 真实阅读器密文 ----------
reader = open(os.path.join(OUT, "reader.html"), encoding="utf-8").read()
ckey = re.search(r"contentKey\s*=\s*'([^']*)'", reader).group(1)
ctx.eval("var __ck=%s;" % json.dumps(ckey))
rplain = ctx.eval("CopyAES.decryptPayload('op0zzpvv.nmn.00p', __ck)")
rj = json.loads(rplain)
urls = [x["url"] for x in rj]
results["reader_real"] = {
    "items": len(rj),
    "first_url": urls[0],
    "ok": len(urls) == 209 and urls[0].endswith("1647114796900001.jpg.c1500x.jpg"),
}

print(json.dumps(results, ensure_ascii=False, indent=1))
allok = (results["gmul_0x57_0x83"] == 0xc1
         and results["sbox_00"] == 0x63 and results["sbox_53"] == 0xed
         and results["sbox_ff"] == 0x16
         and results["nist_cbc"]["ok"]
         and results["chapters_real"]["ok"]
         and results["reader_real"]["ok"])
print("\nALL AES TESTS:", "PASS" if allok else "FAIL")
