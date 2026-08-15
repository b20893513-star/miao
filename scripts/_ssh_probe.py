import socket
import sys
import paramiko

host = "192.168.1.78"
port = 22

s = socket.socket()
s.settimeout(3)
try:
    s.connect((host, port))
    print("PORT_22_OPEN")
except Exception as e:
    print("PORT_22_CLOSED", e)
    sys.exit(1)
finally:
    s.close()

candidates = [
    ("mobile", ""),
    ("mobile", "alpine"),
    ("mobile", "mobile"),
    ("root", "alpine"),
    ("root", ""),
]

for user, pw in candidates:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(
            host,
            port=port,
            username=user,
            password=pw,
            timeout=5,
            allow_agent=False,
            look_for_keys=False,
            banner_timeout=5,
        )
        stdin, stdout, stderr = c.exec_command("whoami; uname -a; echo OK")
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        print(f"SUCCESS user={user!r} password={'EMPTY' if pw == '' else pw}")
        print(out)
        if err.strip():
            print("stderr:", err)
        c.close()
        sys.exit(0)
    except Exception as e:
        print(f"FAIL user={user!r} pw={'EMPTY' if pw == '' else pw}: {type(e).__name__}: {e}")
    finally:
        try:
            c.close()
        except Exception:
            pass

print("NO_CREDENTIAL_WORKED")
sys.exit(2)
