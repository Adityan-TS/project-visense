#!/usr/bin/env python3
"""
ViSense Databricks setup + end-to-end test, run from the Mac.

Reads DATABRICKS_TOKEN and DATABRICKS_WAREHOUSE_ID from ios/Secrets.xcconfig
(never prints the token), then:
  1. creates schema workspace.visense and tables users / transcripts (databricks/setup.sql)
  2. registers a test user, uploads test lines exactly like the app does (MERGE)
  3. reads them back with the app's time-window query
  4. asks the visense-chat model a question (both API styles the app supports)
  5. deletes the test user's rows again

  python3 -I databricks/setup_and_test.py            # setup + test
  python3 -I databricks/setup_and_test.py --setup    # setup only
"""
import json, os, re, sys, time, uuid, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "https://dbc-2a25625f-05c4.cloud.databricks.com"
ENDPOINT = "workspace.default.visense-chat"
T = "workspace.visense"


def secrets():
    vals = {}
    with open(os.path.join(ROOT, "ios", "Secrets.xcconfig")) as f:
        for line in f:
            m = re.match(r"\s*(DATABRICKS_\w+)\s*=\s*(\S*)", line)
            if m:
                vals[m.group(1)] = m.group(2)
    tok, wh = vals.get("DATABRICKS_TOKEN", ""), vals.get("DATABRICKS_WAREHOUSE_ID", "")
    if not tok or not wh:
        sys.exit("Fill DATABRICKS_TOKEN and DATABRICKS_WAREHOUSE_ID in ios/Secrets.xcconfig first.")
    return tok, wh


TOKEN, WAREHOUSE = secrets()


def http(method, path, body=None):
    req = urllib.request.Request(HOST + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="replace")[:600]}


def sql(statement, params=()):
    code, j = http("POST", "/api/2.0/sql/statements", {
        "warehouse_id": WAREHOUSE, "statement": statement,
        "parameters": [{"name": n, "value": v, "type": t} for n, v, t in params],
        "wait_timeout": "30s", "on_wait_timeout": "CONTINUE", "format": "JSON_ARRAY", "disposition": "INLINE"})
    if code != 200:
        raise RuntimeError(f"HTTP {code}: {j.get('error')}")
    t0 = time.time()
    while j.get("status", {}).get("state") in ("PENDING", "RUNNING") and time.time() - t0 < 180:
        time.sleep(2)                                   # warehouse may be starting up
        code, j = http("GET", "/api/2.0/sql/statements/" + j["statement_id"])
    st = j.get("status", {})
    if st.get("state") != "SUCCEEDED":
        raise RuntimeError(f"{st.get('state')}: {st.get('error', {}).get('message', j)}")
    return j.get("result", {}).get("data_array", []) or []


def step(name):
    print(f"\n== {name}")


def setup():
    step("Create schema and tables")
    text = open(os.path.join(ROOT, "databricks", "setup.sql")).read()
    text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))
    for stmt in [s.strip() for s in text.split(";") if s.strip()]:
        sql(stmt)
        print("  ok:", " ".join(stmt.split()[:6]), "...")
    for row in sql(f"SHOW TABLES IN {T}"):
        print("  table:", row[1])


def test():
    user = "test-" + uuid.uuid4().hex[:8]
    session = uuid.uuid4().hex
    now_ms = int(time.time() * 1000)
    lines = [(now_ms - 120_000 + i * 20_000, t) for i, t in enumerate([
        "Hi, thanks for coming in today.",
        "Your next appointment is Friday at 3 PM.",
        "Please take two tablets after dinner.",
        "Call us if the pain gets worse.",
    ])]
    try:
        step(f"Register test user {user} (same MERGE as the app)")
        sql(f"""MERGE INTO {T}.users u USING (SELECT :user_id AS user_id, :name AS display_name, :tz AS timezone) s
                ON u.user_id = s.user_id
                WHEN MATCHED THEN UPDATE SET u.last_seen_at = current_timestamp(), u.timezone = s.timezone
                WHEN NOT MATCHED THEN INSERT (user_id, display_name, timezone, created_at, last_seen_at)
                  VALUES (s.user_id, s.display_name, s.timezone, current_timestamp(), current_timestamp())""",
            [("user_id", user, "STRING"), ("name", "setup test", "STRING"), ("tz", "UTC", "STRING")])
        print("  ok")

        step("Upload 4 lines (same MERGE as the app), twice to prove no duplicates")
        rows, params = [], [("u", user, "STRING")]
        for i, (ms, text) in enumerate(lines):
            rows.append(f"(:l{i}, :u, :s{i}, timestamp_millis(:t{i}), :x{i})")
            params += [(f"l{i}", f"{user}-{i}", "STRING"), (f"s{i}", session, "STRING"),
                       (f"t{i}", str(ms), "BIGINT"), (f"x{i}", text, "STRING")]
        merge = f"""MERGE INTO {T}.transcripts t
            USING (SELECT * FROM VALUES {', '.join(rows)} AS v(line_id, user_id, session_id, ts, text)) v
            ON t.line_id = v.line_id
            WHEN NOT MATCHED THEN INSERT (line_id, user_id, session_id, ts, text)
              VALUES (v.line_id, v.user_id, v.session_id, v.ts, v.text)"""
        sql(merge, params); sql(merge, params)
        n = sql(f"SELECT count(*) FROM {T}.transcripts WHERE user_id = :u", [("u", user, "STRING")])[0][0]
        print("  rows for test user:", n, "(expect 4)")
        assert int(n) == 4

        step("Session index + time-window query (same SQL as the agent)")
        idx = sql(f"""SELECT unix_millis(min(ts)), unix_millis(max(ts)), count(*), min_by(text, ts)
                      FROM {T}.transcripts WHERE user_id = :u AND ts >= current_timestamp() - INTERVAL 14 DAYS
                      GROUP BY session_id ORDER BY 1 DESC LIMIT 30""", [("u", user, "STRING")])
        print("  sessions:", idx)
        got = sql(f"""SELECT unix_millis(ts), text FROM {T}.transcripts
                      WHERE user_id = :u AND ts BETWEEN timestamp_millis(:a) AND timestamp_millis(:b)
                      ORDER BY ts LIMIT 600""",
                  [("u", user, "STRING"), ("a", str(now_ms - 300_000), "BIGINT"), ("b", str(now_ms), "BIGINT")])
        for ms, text in got:
            print(f"  {time.strftime('%H:%M:%S', time.localtime(int(ms) / 1000))}  {text}")
        assert len(got) == 4 and int(got[0][0]) == lines[0][0], "timestamps must round-trip exactly"

        step(f"Ask the model ({ENDPOINT})")
        transcript = "\n".join(t for _, t in got)
        messages = [{"role": "system", "content": "Answer only from this transcript:\n" + transcript},
                    {"role": "user", "content": "When is my next appointment? One sentence."}]
        t0 = time.time()
        code, j = http("POST", f"/serving-endpoints/{ENDPOINT.split('.')[-1]}/invocations",
                       {"messages": messages, "max_tokens": 400})
        api = "classic /serving-endpoints"
        if code in (400, 404):
            code, j = http("POST", "/ai-gateway/mlflow/v1/responses", {
                "model": ENDPOINT, "max_output_tokens": 400, "reasoning": {"effort": "low"},
                "input": [{"role": m["role"], "content": [{"type": "input_text", "text": m["content"]}]} for m in messages]})
            api = "AI Gateway responses"
        print(f"  {api}: HTTP {code} in {time.time() - t0:.1f}s")
        if code != 200:
            print("  model error:", j.get("error"))
        else:
            ans = (j.get("choices") or [{}])[0].get("message", {}).get("content") or j.get("output_text") or \
                  "".join(c.get("text", "") for o in j.get("output", []) if o.get("type") == "message"
                          for c in o.get("content", []) or [])
            print("  answer:", ans)
    finally:
        step("Clean up test user")
        sql(f"DELETE FROM {T}.transcripts WHERE user_id = :u", [("u", user, "STRING")])
        sql(f"DELETE FROM {T}.users WHERE user_id = :u", [("u", user, "STRING")])
        print("  removed")


if __name__ == "__main__":
    setup()
    if "--setup" not in sys.argv:
        test()
    print("\nDone.")
