import subprocess
import time

def check_kasten_ready():
    print("Checking Kasten Pods...")
    cmd = "kubectl get pods -n kasten-io --no-headers"
    
    # Simple retry logic
    for i in range(20):
        output = subprocess.getoutput(cmd)
        if "Running" in output and "0/1" not in output:
            print("✅ Kasten is healthy!")
            return True
        print(f"Waiting for Kasten... (Attempt {i+1}/20)")
        time.sleep(15)
    return False

if __name__ == "__main__":
    if check_kasten_ready():
        print("Ready for Phase 2: Backup Testing.")
    else:
        print("❌ Environment setup failed or timed out.")
