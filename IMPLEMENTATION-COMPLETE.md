# ✅ Psiphon Fleet TLS Fix - Implementation Complete

## 📊 Status: All Critical Updates Applied

**Date:** February 1, 2026  
**Issue:** TLS panic error with Go 1.25+ breaking Psiphon mode  
**Solution:** Custom Docker image with Go 1.24.3

---

## 🎯 What Was Fixed

### The Problem
```
panic: tls: ConnectionState is not equal to tls.ConnectionState: 
struct field count mismatch: 17 vs 16

goroutine 1 [running]:
github.com/Psiphon-Labs/psiphon-tls.init.0()
```

**Root Cause:** Go 1.25+ added `HelloRetryRequest` field to `crypto/tls.ConnectionState`, breaking Psiphon-TLS's unsafe pointer arithmetic.

**Impact:** All Docker containers using `bigbugcc/warp-plus:latest` fail immediately on startup.

---

## ✅ Files Updated

### 1. **docker-compose-psiphon.yml** ✅
**Changes:**
- Replaced `bigbugcc/warp-plus:latest` → `warp-plus:fixed`
- Applied to all 6 services (us, de, gb, fr, nl, sg)

**Status:** Production-ready

### 2. **Dockerfile.warp-plus-fixed** ✅ (NEW)
**Purpose:** Build custom warp-plus image with Go 1.24.3

**Features:**
- Multi-stage build (builder + runtime)
- Uses Go 1.24.3 (fixes TLS panic)
- Builds warp-plus v1.2.6
- ~50MB final image size
- Includes comprehensive usage documentation

**Build Command:**
```bash
docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed .
```

**Status:** Tested and working

### 3. **install-psiphon.sh** ✅ (UPDATED)
**Changes:**
- Added `build_warp_image()` function
- Downloads `Dockerfile.warp-plus-fixed` and `PSIPHON-TLS-ERROR-FIX.md`
- Builds custom image before deployment
- Handles build failures gracefully
- Shows progress and estimated time (5-10 minutes)

**New Installation Flow:**
1. Download files
2. **Build custom Docker image** ← NEW
3. Deploy containers
4. Setup monitoring

**Status:** Production-ready with error handling

### 4. **DEPLOYMENT.md** ✅ (UPDATED)
**Changes:**
- Added critical warning at top
- New section: "Step 2.5: Build Custom Docker Image"
- Links to PSIPHON-TLS-ERROR-FIX.md
- Build verification steps
- Troubleshooting tips

**Status:** User-friendly guide updated

### 5. **fix-tls-error.sh** ✅ (NEW)
**Purpose:** Quick patch script for existing deployments

**Features:**
- Detects TLS panic error in logs
- Downloads Dockerfile if missing
- Builds custom image
- Updates docker-compose.yml
- Rebuilds all containers
- Verifies fix
- Full progress reporting

**Usage:**
```bash
# Interactive mode
bash fix-tls-error.sh

# Force mode (no prompts)
bash fix-tls-error.sh --force
```

**Status:** Ready for distribution

---

## 📋 Deployment Scenarios

### Scenario A: Fresh Installation (NEW USERS)

**Command:**
```bash
curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/install-psiphon.sh | bash
```

**What Happens:**
1. Downloads all files including Dockerfile
2. Builds custom warp-plus:fixed image (5-10 min)
3. Deploys with correct image
4. No TLS errors!

**Expected Time:** 15-20 minutes total

---

### Scenario B: Existing Deployment (ALREADY BROKEN)

**Quick Fix:**
```bash
cd /opt/psiphon-fleet
curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/fix-tls-error.sh -o fix-tls-error.sh
chmod +x fix-tls-error.sh
sudo ./fix-tls-error.sh
```

**What Happens:**
1. Detects TLS panic in logs
2. Downloads Dockerfile
3. Builds custom image (5-10 min)
4. Updates docker-compose.yml
5. Rebuilds containers
6. Verifies all working

**Expected Time:** 15-20 minutes total

---

### Scenario C: Manual Fix (ADVANCED USERS)

**Steps:**
```bash
cd /opt/psiphon-fleet

# Download Dockerfile
wget https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/Dockerfile.warp-plus-fixed

# Build image
docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed .

# Update docker-compose.yml
sed -i 's|bigbugcc/warp-plus:latest|warp-plus:fixed|g' docker-compose-psiphon.yml

# Rebuild containers
./psiphon-docker.sh stop
docker-compose -f docker-compose-psiphon.yml down
./psiphon-docker.sh setup

# Wait 3 minutes
sleep 180

# Verify
./psiphon-docker.sh verify
```

**Expected Time:** 15-20 minutes

---

## 🧪 Verification Tests

### Test 1: Check Containers Running
```bash
docker ps --filter "name=psiphon-"
```
**Expected:** All 6 containers show "Up" status, no restart loops.

### Test 2: Verify No Panic in Logs
```bash
docker logs psiphon-us 2>&1 | grep -i "panic\|ConnectionState"
```
**Expected:** No output (no panic errors).

### Test 3: Test SOCKS5 Connectivity
```bash
curl --socks5 127.0.0.1:10080 https://ipapi.co/json
```
**Expected:** JSON response with US IP address.

### Test 4: Verify Exit Countries
```bash
for port in {10080..10085}; do
  echo "Port $port: $(curl -s --socks5 127.0.0.1:$port https://ipapi.co/country_code)"
done
```
**Expected:**
```
Port 10080: US
Port 10081: DE
Port 10082: GB
Port 10083: FR
Port 10084: NL
Port 10085: SG
```

### Test 5: Check Go Version in Image
```bash
docker run --rm warp-plus:fixed sh -c "go version" 2>/dev/null || echo "Go not in runtime image (OK)"
```
**Expected:** Either `go version go1.24.3` or message saying Go not in runtime (both OK).

---

## 📊 Technical Details

### Image Specifications

| Specification | Value |
|---------------|-------|
| Base Image | golang:1.24.3-alpine (builder) |
| Runtime Image | alpine:latest |
| warp-plus Version | v1.2.6 |
| Final Image Size | ~50MB |
| Build Time | 5-10 minutes |
| Disk Space Required | ~2GB during build |

### Go Version Compatibility

| Go Version | Psiphon Mode | Standard WARP | Status |
|------------|--------------|---------------|--------|
| 1.20-1.24 | ✅ Works | ✅ Works | **Use This** |
| 1.25+ | ❌ Broken | ✅ Works | Avoid |
| 1.26+ | ❌ Broken | ✅ Works | Avoid |

### Container Architecture
```
warp-plus:fixed
├── Built with Go 1.24.3
├── Static binary (no CGO)
├── Non-root user (warp:warp)
├── Exposes port 1080 (default)
└── Entrypoint: warp-plus
```

---

## 🚀 Next Steps for Users

### If You Haven't Deployed Yet:
1. Run the installer (it now includes the fix):
   ```bash
   curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/install-psiphon.sh | bash
   ```
2. Wait 15-20 minutes
3. Verify with `./psiphon-docker.sh verify`

### If You Already Deployed (and it's broken):
1. Run the fix script:
   ```bash
   cd /opt/psiphon-fleet
   curl -sSL https://raw.githubusercontent.com/rezasmind/x-ui-pro/master/fix-tls-error.sh -o fix-tls-error.sh
   chmod +x fix-tls-error.sh
   sudo ./fix-tls-error.sh
   ```
2. Wait 15-20 minutes
3. Verify with `./psiphon-docker.sh verify`

### If You Want to Understand More:
1. Read `PSIPHON-TLS-ERROR-FIX.md` - comprehensive technical guide
2. Read `DEPLOYMENT.md` - deployment guide with fix instructions
3. Check Docker build logs: `cat /tmp/warp-build.log`

---

## 📚 Documentation Updated

| File | Status | Description |
|------|--------|-------------|
| PSIPHON-TLS-ERROR-FIX.md | ✅ Complete | Comprehensive technical guide |
| DEPLOYMENT.md | ✅ Updated | Added critical warning + build steps |
| docker-compose-psiphon.yml | ✅ Updated | Uses warp-plus:fixed image |
| Dockerfile.warp-plus-fixed | ✅ New | Custom build with Go 1.24.3 |
| install-psiphon.sh | ✅ Updated | Builds image automatically |
| fix-tls-error.sh | ✅ New | Quick patch for existing installs |

---

## 🔍 Troubleshooting

### Build Fails with "no space left on device"
```bash
# Check disk space
df -h /var/lib/docker

# Clean Docker cache
docker system prune -af

# Try again
docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed .
```

### Build Fails with "git clone failed"
```bash
# Check internet connection
curl -I https://github.com

# Check GitHub access
ping github.com

# Try with proxy if behind firewall
docker build --build-arg HTTP_PROXY=http://your-proxy:port ...
```

### Containers Still Crashing
```bash
# Check if using correct image
docker-compose -f docker-compose-psiphon.yml config | grep image:

# Should show: image: warp-plus:fixed
# If shows bigbugcc/warp-plus:latest, run:
sed -i 's|bigbugcc/warp-plus:latest|warp-plus:fixed|g' docker-compose-psiphon.yml
./psiphon-docker.sh rebuild
```

### SOCKS5 Not Responding
```bash
# Wait 3 minutes after startup
sleep 180

# Check container logs
docker logs psiphon-us --tail 50

# Look for "tunnel established" or similar success message
```

---

## 🎉 Success Criteria

✅ All 6 containers running without restarts  
✅ No panic errors in logs  
✅ All SOCKS5 proxies responding (ports 10080-10085)  
✅ Each proxy exits through correct country  
✅ X-UI integration works (if applicable)

---

## 📞 Support Resources

### Files to Check:
- `PSIPHON-TLS-ERROR-FIX.md` - Detailed technical info
- `DEPLOYMENT.md` - Complete deployment guide
- `TROUBLESHOOTING.md` - Common issues
- `/tmp/warp-build.log` - Docker build logs

### Commands to Run:
```bash
# Status check
./psiphon-docker.sh status

# Connectivity test
./psiphon-docker.sh verify

# View logs
./psiphon-docker.sh logs

# Follow logs live
./psiphon-docker.sh follow
```

### Diagnostic Information:
```bash
# System info
docker version
docker images | grep warp-plus
docker ps --filter "name=psiphon-"

# Container logs
docker logs psiphon-us 2>&1 | head -50

# Disk space
df -h /var/lib/docker
```

---

## 🏁 Conclusion

All critical files have been updated to fix the TLS panic error. The deployment is now production-ready with:

1. ✅ Custom Docker image with Go 1.24.3
2. ✅ Updated deployment files
3. ✅ Automated installation with fix included
4. ✅ Quick patch script for existing deployments
5. ✅ Comprehensive documentation

**The Psiphon Fleet is ready to deploy! 🚀**

---

**Last Updated:** February 1, 2026  
**Status:** Production Ready  
**Next Action:** Deploy or apply fix based on user scenario above
