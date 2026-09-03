import urllib.request
import json
import time
import sys

def check_queue():
    try:
        # Standard timeout for the request itself
        with urllib.request.urlopen("http://localhost:8080/queue", timeout=10) as response:
            if response.status != 200:
                print(f"Healthcheck failed: HTTP {response.status}")
                return False
            data = json.loads(response.read().decode())
        
        now_ms = time.time() * 1000
        # 1 hour = 60 minutes * 60 seconds * 1000 milliseconds
        timeout_ms = 60 * 60 * 1000 
        
        # Check running items
        # Format: [index, prompt_id, workflow, extra_info, outputs]
        for item in data.get("queue_running", []):
            if len(item) > 3 and isinstance(item[3], dict) and "create_time" in item[3]:
                create_time = item[3]["create_time"]
                elapsed_min = (now_ms - create_time) / 1000 / 60
                if now_ms - create_time > timeout_ms:
                    print(f"Running job {item[1]} is too old: {elapsed_min:.1f} minutes")
                    return False
        
        # Check pending items
        for item in data.get("queue_pending", []):
            if len(item) > 3 and isinstance(item[3], dict) and "create_time" in item[3]:
                create_time = item[3]["create_time"]
                elapsed_min = (now_ms - create_time) / 1000 / 60
                if now_ms - create_time > timeout_ms:
                    print(f"Pending job {item[1]} is too old: {elapsed_min:.1f} minutes")
                    return False
                    
        return True
    except Exception as e:
        print(f"Healthcheck error: {e}")
        return False

if __name__ == "__main__":
    if check_queue():
        sys.exit(0)
    else:
        sys.exit(1)
