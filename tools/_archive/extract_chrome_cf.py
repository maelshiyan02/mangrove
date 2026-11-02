"""Extract cf_clearance from Chrome cookie DB — fixed AES-GCM (v10/v20) decryption."""
import sqlite3, json, os, sys, base64

def dpapi_decrypt(data):
    """DPAPI CryptUnprotectData."""
    import win32crypt
    return win32crypt.CryptUnprotectData(data, None, None, None, 0)[1]

def get_chrome_aes_key():
    """Get AES-GCM key from Chrome's Local State file."""
    local_state_path = os.path.join(
        os.environ["LOCALAPPDATA"], "Google", "Chrome", "User Data", "Local State"
    )
    if not os.path.exists(local_state_path):
        print(f"Local State not found at {local_state_path}", file=sys.stderr)
        return None
    
    with open(local_state_path, "r", encoding="utf-8") as f:
        local_state = json.load(f)
    
    encrypted_key = base64.b64decode(
        local_state["os_crypt"]["encrypted_key"]
    )
    print(f"encrypted_key raw first 10 bytes: {encrypted_key[:10]}")
    
    # Chrome prefixes: "DPAPI" or "v10"/"v11"
    for prefix in [b"DPAPI", b"v10", b"v11"]:
        if encrypted_key.startswith(prefix):
            encrypted_key = encrypted_key[len(prefix):]
            print(f"Stripped prefix {prefix}")
            break
    
    try:
        aes_key = dpapi_decrypt(encrypted_key)
        print(f"DPAPI decrypt OK! AES key len={len(aes_key)}")
        return aes_key
    except Exception as e:
        print(f"DPAPI decrypt encrypted_key failed: {e}", file=sys.stderr)
        return None

def chrome_decrypt(encrypted_value, aes_key):
    """Decrypt Chrome cookie value — handles v10 (DPAPI) and v20 (AES-GCM)."""
    try:
        if encrypted_value[:3] in (b'v10', b'v11'):
            # Chrome 80-126: DPAPI wrapped AES-CBC
            decrypted = dpapi_decrypt(encrypted_value)
            return decrypted.decode('utf-8', errors='ignore')
        
        elif encrypted_value[:3] == b'v20':
            # Chrome 127+: AES-GCM
            # Format: 3 bytes "v20" + 12 bytes nonce + ciphertext (includes 16-byte tag at end)
            payload = encrypted_value[3:]
            print(f"  v20 decrypt: total={len(encrypted_value)} payload={len(payload)}")
            nonce = payload[:12]
            ciphertext_tag = payload[12:]
            print(f"  nonce hex: {nonce.hex()}")
            print(f"  ciphertext+tag len: {len(ciphertext_tag)}")
            
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
            aesgcm = AESGCM(aes_key)
            decrypted = aesgcm.decrypt(nonce, ciphertext_tag, None)
            result = decrypted.decode('utf-8', errors='ignore')
            print(f"  AES-GCM result len={len(result)}")
            return result
        
        elif encrypted_value[:3] == b'v10':
            return dpapi_decrypt(encrypted_value).decode('utf-8', errors='ignore')
        
        else:
            # Unknown format, try raw DPAPI
            return dpapi_decrypt(encrypted_value).decode('utf-8', errors='ignore')
    except Exception as e:
        import traceback
        print(f"Decrypt fail (prefix={encrypted_value[:5].hex()}): {e}\n{traceback.format_exc()}", file=sys.stderr)
        return None

def main():
    cookie_out = r"C:\Users\Administrator\AppData\Roaming\io.github.maelshiyan02\mangrove\cf_cookie.json"
    dst = os.path.join(os.environ["TEMP"], "chrome_cookie_copy.db")
    
    if not (os.path.exists(dst) and os.path.getsize(dst) > 100000):
        print("No copied Chrome cookie DB found!", file=sys.stderr)
        sys.exit(1)
    
    print("Getting Chrome AES key from Local State...")
    aes_key = get_chrome_aes_key()
    print(f"AES key available: {aes_key is not None}")
    
    conn = sqlite3.connect(dst)
    c = conn.cursor()
    c.execute("SELECT host_key, name, encrypted_value FROM cookies WHERE host_key LIKE '%comix.to%'")
    rows = c.fetchall()
    conn.close()
    
    if not rows:
        print("No comix.to cookies found!", file=sys.stderr)
        sys.exit(1)
    
    for host, name, enc_val in rows:
        prefix = enc_val[:3].hex() if len(enc_val) >= 3 else enc_val.hex()
        print(f"Cookie: host={host} name={name} prefix=0x{prefix} raw_len={len(enc_val)}")
        
        dec_val = chrome_decrypt(enc_val, aes_key)
        if dec_val:
            print(f"  → DECRYPTED! len={len(dec_val)} preview={dec_val[:40]}...")
        else:
            print(f"  → FAILED to decrypt")
        
        if name == "cf_clearance" and dec_val and len(dec_val) > 100:
            data = {"cf_clearance": dec_val, "domain": host}
            with open(cookie_out, "w") as f:
                json.dump(data, f, indent=2)
            print(f"\n✅ cf_clearance SAVED to {cookie_out}")
            sys.exit(0)
    
    print("\n❌ No valid cf_clearance cookie extracted!", file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    main()
