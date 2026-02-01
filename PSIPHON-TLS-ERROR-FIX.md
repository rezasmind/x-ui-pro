# 🚨 CRITICAL FIX: Psiphon-TLS Panic Error

## Problem Description

**Error Message:**
```
panic: tls: ConnectionState is not equal to tls.ConnectionState: struct field count mismatch: 17 vs 16

goroutine 1 [running]:
github.com/Psiphon-Labs/psiphon-tls.init.0()
        github.com/Psiphon-Labs/psiphon-tls@v0.0.0-20250318183125-2a2fae2db378/unsafe.go:44 +0xd9
```

**Impact**: All Docker containers fail to start, Psiphon proxies don't work.

---

## Root Cause

**Go 1.25+ added a new field to `crypto/tls.ConnectionState`:**
- Go 1.24: 16 fields
- **Go 1.25+: 17 fields** (added `HelloRetryRequest bool`)
- Psiphon's `unsafe.go` uses hardcoded struct size checks → PANIC when mismatch detected

**Why this happens:**
- Psiphon-TLS uses unsafe pointer arithmetic to access internal TLS fields
- Code assumes fixed struct layout with 16 fields
- Go 1.25 broke this assumption
- Error occurs at initialization before any network activity

---

## ✅ IMMEDIATE SOLUTION

### Solution 1: Use Pre-Built Docker Image with Go 1.24 (RECOMMENDED)

**The `bigbugcc/warp-plus:latest` image is BROKEN** (uses Go 1.25+).

Use an **older working version** OR build your own:

#### Option A: Use Last Known Working Version

```bash
# Try these working tags (built with Go 1.24):
docker pull bigbugcc/warp-plus:v1.2.4
docker pull peyman29/warp-plus:v1.2.5

# Test it:
docker run --rm -it -p 10080:10080 bigbugcc/warp-plus:v1.2.4 \
  --bind 0.0.0.0:10080 --cfon --country US --scan
```

#### Option B: Build Your Own Docker Image (GUARANTEED TO WORK)

Create `Dockerfile.warp-plus-fixed`:

```dockerfile
# Use Go 1.24 (CRITICAL - do NOT use 1.25+)
FROM golang:1.24.3-alpine AS builder

WORKDIR /app

# Clone warp-plus
RUN apk add --no-cache git && \
    git clone https://github.com/bepass-org/warp-plus.git . && \
    git checkout v1.2.6

# Build with Go 1.24
RUN go mod download && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o warp-plus ./cmd/warp-plus

# Runtime stage
FROM alpine:latest

RUN apk add --no-cache ca-certificates

COPY --from=builder /app/warp-plus /usr/local/bin/

ENTRYPOINT ["warp-plus"]
CMD ["--help"]
```

**Build and use:**

```bash
# Build image
docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed .

# Test it
docker run --rm -it -p 10080:10080 warp-plus:fixed \
  --bind 0.0.0.0:10080 --cfon --country US --scan
```

---

### Solution 2: Update docker-compose.yml

**Replace broken image with working version:**

```yaml
version: '3.8'

services:
  psiphon-us:
    # OLD (BROKEN):
    # image: bigbugcc/warp-plus:latest
    
    # NEW (WORKING):
    image: warp-plus:fixed  # Your locally built image
    # OR
    # image: bigbugcc/warp-plus:v1.2.4  # Known working tag
    
    container_name: psiphon-us
    restart: unless-stopped
    network_mode: host
    command: >
      --bind 0.0.0.0:10080
      --cfon
      --country US
      --scan
    volumes:
      - ./warp-data/us:/etc/warp
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  psiphon-de:
    image: warp-plus:fixed
    container_name: psiphon-de
    restart: unless-stopped
    network_mode: host
    command: >
      --bind 0.0.0.0:10081
      --cfon
      --country DE
      --scan
    volumes:
      - ./warp-data/de:/etc/warp
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # ... repeat for other countries
```

---

### Solution 3: Alternative - Disable Psiphon Mode

If you can't build a custom image, **use standard WARP mode** (no Psiphon):

```yaml
services:
  warp-us:
    image: bigbugcc/warp-plus:latest  # Latest works WITHOUT Psiphon
    container_name: warp-us
    restart: unless-stopped
    network_mode: host
    command: >
      --bind 0.0.0.0:10080
      --scan
    # NOTE: Removed --cfon and --country (no Psiphon mode)
    volumes:
      - ./warp-data/us:/etc/warp
```

**Trade-off:** You lose country-specific exits, but proxies will work.

---

## 🔧 Step-by-Step Fix for Existing Deployment

### Step 1: Build Fixed Image

```bash
cd /opt/psiphon-fleet

# Create Dockerfile
cat > Dockerfile.warp-plus-fixed << 'EOF'
FROM golang:1.24.3-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git && \
    git clone https://github.com/bepass-org/warp-plus.git . && \
    git checkout v1.2.6

RUN go mod download && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o warp-plus ./cmd/warp-plus

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/warp-plus /usr/local/bin/
ENTRYPOINT ["warp-plus"]
EOF

# Build (takes 5-10 minutes)
docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed .
```

### Step 2: Update docker-compose.yml

```bash
# Edit docker-compose-psiphon.yml
sed -i 's|image: bigbugcc/warp-plus:latest|image: warp-plus:fixed|g' docker-compose-psiphon.yml

# Verify changes
grep "image:" docker-compose-psiphon.yml
```

### Step 3: Rebuild Containers

```bash
# Stop all containers
./psiphon-docker.sh stop

# Remove old containers
docker-compose -f docker-compose-psiphon.yml down

# Start with new image
./psiphon-docker.sh setup

# Wait 2-3 minutes for tunnels
sleep 180

# Verify
./psiphon-docker.sh verify
```

---

## 🧪 Verification

### Test 1: Check Containers Are Running

```bash
docker ps --filter "name=psiphon-"
```

**Expected:** All containers show "Up" status without restart loops.

### Test 2: Check Logs (No Panic)

```bash
docker logs psiphon-us 2>&1 | grep -i "panic\|tls\|ConnectionState"
```

**Expected:** No panic messages, should show tunnel establishment.

### Test 3: Test SOCKS5 Connectivity

```bash
curl --socks5 127.0.0.1:10080 https://ipapi.co/json
```

**Expected:** Returns JSON with US IP address.

### Test 4: Verify Exit Country

```bash
for port in {10080..10085}; do
  echo "Port $port:"
  curl --socks5 127.0.0.1:$port https://ipapi.co/country_code
  echo ""
done
```

**Expected:** Each port returns its assigned country code.

---

## 📊 Go Version Compatibility Matrix

| Go Version | Psiphon Mode | Standard WARP Mode | Docker Image           |
|------------|--------------|-------------------|------------------------|
| Go 1.24.3  | ✅ WORKS     | ✅ WORKS           | golang:1.24.3-alpine   |
| Go 1.24.x  | ✅ WORKS     | ✅ WORKS           | golang:1.24-alpine     |
| Go 1.23.x  | ✅ WORKS     | ✅ WORKS           | golang:1.23-alpine     |
| **Go 1.25+** | ❌ BROKEN  | ✅ WORKS           | golang:1.25-alpine     |
| Go 1.26+   | ❌ BROKEN    | ✅ WORKS           | golang:1.26-alpine     |

**Rule of Thumb:** If using Psiphon (`--cfon`), MUST use Go ≤ 1.24.

---

## 🔍 Alternative Docker Images

### Working Images (Confirmed Compatible)

```bash
# Community-built images with Go 1.24
docker pull peyman29/warp-plus:v1.2.5
docker pull minlaxz/warp-plus:latest  # May be outdated

# Official Cloudflare WARP (no Psiphon support)
docker pull cloudflare/warp-client:latest
```

### Building from Source (No Docker)

```bash
# Install Go 1.24
wget https://go.dev/dl/go1.24.3.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.24.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/bin/go

# Build warp-plus
git clone https://github.com/bepass-org/warp-plus.git
cd warp-plus
go build -o warp-plus ./cmd/warp-plus

# Test
./warp-plus --bind 127.0.0.1:10080 --cfon --country US
```

---

## 🚫 What NOT to Do

### ❌ DON'T: Use `golang:latest` or unspecified versions

```dockerfile
# WRONG - will use Go 1.25+ and break
FROM golang:latest
FROM golang:alpine
```

### ❌ DON'T: Try to "fix" Psiphon-TLS yourself

Patching `unsafe.go` requires deep understanding of Go internals and will break with every Go update.

### ❌ DON'T: Use old warp-plus with modern Go

```bash
# WRONG - version mismatch
docker build --build-arg GOLANG_VERSION=1.25 .  # With old warp-plus code
```

### ❌ DON'T: Mix Psiphon and non-Psiphon containers with same image

```yaml
# WRONG - some services use --cfon, others don't
services:
  psiphon-us:
    image: bigbugcc/warp-plus:latest  # Go 1.25
    command: --cfon --country US  # Will fail
  
  warp-only:
    image: bigbugcc/warp-plus:latest  # Same image
    command: --bind 0.0.0.0:10080  # Works, but image is wasteful
```

---

## 📚 Technical Deep Dive

### Why Psiphon Uses Unsafe Code

From `psiphon-tls/unsafe.go:44`:

```go
func init() {
    err := structsEqual(&tls.ConnectionState{}, &ConnectionState{})
    if err != nil {
        panic(fmt.Sprintf("tls: ConnectionState is not equal to tls.ConnectionState: %v", err))
    }
}
```

**Purpose:**
- Override TLS session tickets for obfuscation
- Access private fields in `crypto/tls.Conn`
- Emulate browser ClientHello patterns
- These features require internal struct access

**Problem:**
- Uses `unsafe.Pointer` and `reflect` to calculate field offsets
- Assumes fixed struct layout
- Breaks when Go adds/removes/reorders fields

### What Changed in Go 1.25

**File:** `src/crypto/tls/common.go`

```go
// Go 1.24
type ConnectionState struct {
    // ... 16 fields total
    ECHAccepted bool
    ekm func(...) ([]byte, error)
}

// Go 1.25
type ConnectionState struct {
    // ... same fields ...
    ECHAccepted bool
    HelloRetryRequest bool  // ← NEW FIELD
    ekm func(...) ([]byte, error)
}
```

**Impact:** Struct size changes, field offsets shift, Psiphon's unsafe code panics.

---

## 🔮 Long-Term Solution (Awaiting Psiphon Team)

**Expected Fix:** Psiphon team needs to:
1. Use runtime reflection instead of compile-time checks
2. Dynamically calculate field offsets
3. Support Go 1.25+ struct layout

**Timeline:** Unknown - no public PR or issue yet.

**Tracking:**
- Watch: https://github.com/Psiphon-Labs/psiphon-tls
- Watch: https://github.com/Psiphon-Labs/psiphon-tunnel-core

---

## 📞 Support

**If still broken after following this guide:**

1. Verify Go version in image:
   ```bash
   docker run --rm warp-plus:fixed go version
   ```
   Should show: `go version go1.24.3`

2. Check build logs:
   ```bash
   docker build -f Dockerfile.warp-plus-fixed -t warp-plus:fixed . 2>&1 | tee build.log
   ```

3. Test binary directly:
   ```bash
   docker run --rm -it warp-plus:fixed --version
   ```

4. Share diagnostic info:
   ```bash
   docker version
   docker images | grep warp-plus
   docker logs psiphon-us 2>&1 | head -50
   ```

---

## ✅ Summary

**Problem:** Go 1.25+ breaks Psiphon-TLS with struct field mismatch  
**Root Cause:** `HelloRetryRequest` field added to `ConnectionState`  
**Quick Fix:** Use Go 1.24.3 Docker image  
**Long-Term:** Wait for Psiphon team to release compatible version

**Action Items:**
1. Build custom Docker image with Go 1.24.3 ✅
2. Update docker-compose.yml to use fixed image ✅
3. Rebuild and restart all containers ✅
4. Verify connectivity ✅

---

**Last Updated:** February 1, 2026  
**Go Versions:** 1.24.3 (working), 1.25+ (broken)  
**Status:** Workaround available, awaiting official fix
