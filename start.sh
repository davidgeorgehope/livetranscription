#!/bin/bash

# Live Transcription - Start Script
# Starts both the backend API server and frontend dev server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load .env file if it exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Check for GEMINI_API_KEY
if [ -z "$GEMINI_API_KEY" ]; then
    echo -e "${RED}Error: GEMINI_API_KEY environment variable is not set${NC}"
    echo "Please set it with: export GEMINI_API_KEY=your_key_here"
    echo "Or create a .env file with: GEMINI_API_KEY=your_key_here"
    exit 1
fi

# Check if venv exists
if [ ! -d ".venv" ]; then
    echo -e "${YELLOW}Creating Python virtual environment...${NC}"
    python3 -m venv .venv
fi

# Check if package is installed (look for fastapi as indicator)
source .venv/bin/activate
if ! python -c "import fastapi" 2>/dev/null; then
    echo -e "${YELLOW}Installing backend dependencies...${NC}"
    pip install -U pip
    pip install -e .
fi

# Check if node_modules exists
if [ ! -d "web/node_modules" ]; then
    echo -e "${YELLOW}Installing frontend dependencies...${NC}"
    (cd web && npm install)
fi

# Cleanup function to kill background processes on exit
cleanup() {
    echo -e "\n${YELLOW}Shutting down...${NC}"
    if [ ! -z "$BACKEND_PID" ]; then
        kill $BACKEND_PID 2>/dev/null || true
    fi
    if [ ! -z "$FRONTEND_PID" ]; then
        kill $FRONTEND_PID 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

echo -e "${GREEN}Starting Live Transcription...${NC}"
echo ""

# Start backend server
echo -e "${YELLOW}Starting backend server on http://127.0.0.1:8765${NC}"
livetranscribe web --host 127.0.0.1 --port 8765 &
BACKEND_PID=$!

# Give backend a moment to start
sleep 2

# Check if backend started successfully
if ! kill -0 $BACKEND_PID 2>/dev/null; then
    echo -e "${RED}Backend failed to start${NC}"
    exit 1
fi

# Start frontend dev server
echo -e "${YELLOW}Starting frontend dev server...${NC}"
(cd web && npm run dev) &
FRONTEND_PID=$!

# Give frontend a moment to start
sleep 3

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Live Transcription is running!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Frontend:  ${GREEN}http://localhost:5173${NC}"
echo -e "Backend:   ${GREEN}http://127.0.0.1:8765${NC}"
echo ""
echo -e "Press ${YELLOW}Ctrl+C${NC} to stop both servers"
echo ""

# Wait for either process to exit
wait
