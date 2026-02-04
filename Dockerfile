# =============================================================================
# Multi-stage Dockerfile for FastAPI API using UV
# =============================================================================

# =============================================================================
# Stage 1: Build with UV
# =============================================================================
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS builder

# Install system dependencies for building native packages
# gcc, g++ needed for psycopg2-binary compilation
# libpq-dev for PostgreSQL client libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    curl \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Arguments for CodeArtifact configuration
ARG UV_INDEX

# Set UV environment variables for optimal builds
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_INDEX=${UV_INDEX} \
    UV_PYTHON=python3.13

# Copy dependency files first for better Docker layer caching
COPY pyproject.toml uv.lock ./

# Install production dependencies only (without installing the project itself)
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# Copy source code
COPY app/ ./app/

# Install the project itself
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# =============================================================================
# Stage 2: Test (for CI)
# =============================================================================
FROM builder AS test

# Install dev dependencies for testing
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen

# Copy tests and scripts
COPY tests/ ./tests/
COPY scripts/ ./scripts/

# Lint check (fail build if lint or type errors found)
RUN uv run ruff check app/
RUN uv run mypy app/

# Run tests
RUN uv run pytest tests/ -v --tb=short

# =============================================================================
# Stage 3: Development
# =============================================================================
FROM builder AS development

# Install all dev dependencies
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen

# Copy tests and scripts for development
COPY tests/ ./tests/
COPY scripts/ ./scripts/

# Environment for development
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    ENVIRONMENT=local

# Development runs as root (acceptable for local dev)
USER root

# Run the API in development mode with hot reload
CMD ["fastapi", "dev", "app/app.py", "--host", "0.0.0.0", "--port", "8000"]

# =============================================================================
# Stage 4: Production
# =============================================================================
FROM python:3.13-slim-bookworm AS production

# Create non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Set working directory
WORKDIR /app

# Install only runtime dependencies
# libpq5 for PostgreSQL client runtime libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copy the virtual environment from builder
COPY --from=builder /app/.venv /app/.venv

# Copy source code
COPY app/ ./app/

# Set ownership for non-root user
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Environment variables
ENV PATH="/usr/local/bin:/app/.venv/bin:$PATH" \
    PYTHONPATH=/app:/app/.venv/lib/python3.13/site-packages \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    ENVIRONMENT=production

# Expose port
EXPOSE 8000

# Health check using Python urllib (no curl needed)
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Run the API with FastAPI CLI
CMD ["python", "-m", "fastapi", "run", "app/app.py", "--host", "0.0.0.0", "--port", "8000"]
