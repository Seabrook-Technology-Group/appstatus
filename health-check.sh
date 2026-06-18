#!/bin/bash
set -e

# Determine if we should commit changes
# In the original repository we'll just print the result of status checks,
# without committing. This avoids generating several commits that would make
# later upstream merges messy for anyone who forked us.
commit=true
origin=$(git remote get-url origin)
if [[ $origin == *statsig-io/statuspage* ]]; then
  commit=false
fi

KEYSARRAY=()
URLSARRAY=()

urlsConfig="./urls.cfg"
echo "Reading $urlsConfig"
if [[ ! -f "$urlsConfig" ]]; then
  echo "Error: $urlsConfig not found!"
  exit 1
fi

while IFS='=' read -r key url; do
  # Skip empty lines and comments
  [[ -z "$key" || "$key" == \#* ]] && continue
  # Trim whitespace
  key=$(echo "$key" | xargs)
  url=$(echo "$url" | xargs)
  echo "  $key=$url"
  KEYSARRAY+=("$key")
  URLSARRAY+=("$url")
done < "$urlsConfig"

echo "***********************"
echo "Starting health checks with ${#KEYSARRAY[@]} configs at $(date)"

mkdir -p logs

# Process each URL
for (( index=0; index < ${#KEYSARRAY[@]}; index++ )); do
  key="${KEYSARRAY[index]}"
  url="${URLSARRAY[index]}"
  
  # Sanitize key for filename (replace spaces with underscores, remove special chars)
  sanitized_key=$(echo "$key" | tr ' ' '_' | sed 's/[^a-zA-Z0-9._-]//g')
  log_file="logs/${sanitized_key}_report.log"
  
  echo ""
  echo "Checking: $key"
  echo "URL: $url"
  echo "Log file: $log_file"

  result="failed"
  response_code="000"
  
  # Try up to 4 times with 5-second delays between attempts
  for attempt in 1 2 3 4; do
    echo -n "  Attempt $attempt/4... "
    
    # Use timeout to prevent hanging requests (max 10 seconds)
    response_code=$(curl -w '%{http_code}' --silent --output /dev/null --max-time 10 --connect-timeout 5 "$url" 2>/dev/null || echo "000")
    
    # Success if 2xx, 3xx status codes (or some 4xx like 401 for auth-protected endpoints)
    if [[ "$response_code" == "200" || "$response_code" == "202" || "$response_code" == "301" || "$response_code" == "302" || "$response_code" == "307" || "$response_code" == "401" || "$response_code" == "403" ]]; then
      result="success"
      echo "✓ (HTTP $response_code)"
      break
    else
      echo "✗ (HTTP $response_code)"
      if [[ $attempt -lt 4 ]]; then
        sleep 5
      fi
    fi
  done
  
  dateTime=$(date +'%Y-%m-%d %H:%M')
  
  if [[ $commit == true ]]; then
    # Append result to log file
    echo "$dateTime, $result" >> "$log_file"
    
    # Keep only the last 2000 entries to prevent log file bloat
    tail -2000 "$log_file" > "$log_file.tmp" && mv "$log_file.tmp" "$log_file"
    
    echo "  Result: $result - logged to $log_file"
  else
    echo "  Result: $result (not committing)"
  fi
done

echo ""
echo "Health checks completed at $(date)"

# Commit and push changes if in a real repository
if [[ $commit == true ]]; then
  echo "***********************"
  echo "Committing changes to Git..."
  
  # Configure git user for CI/CD environments (GitHub Actions)
  git config --global user.name 'Automated Health Check'
  git config --global user.email 'francis.delgado@connectedmanufacturing.com'
  
  # Stage and commit log files
  git add -A --force logs/
  
  if git diff --cached --quiet; then
    echo "No changes to commit"
  else
    git commit -m "[Automated] Update Health Check Logs - $(date +'%Y-%m-%d %H:%M:%S')"
    git push
    echo "Changes pushed successfully"
  fi
fi

echo "Done!"
