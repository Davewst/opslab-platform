CREATE TABLE IF NOT EXISTS runs (
  id         bigserial PRIMARY KEY,
  sandbox    text        NOT NULL,
  score      int         NOT NULL,
  total      int         NOT NULL,
  detail     jsonb       NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS runs_created_idx ON runs (created_at DESC);

CREATE TABLE IF NOT EXISTS cve_cache (
  cve_id     text PRIMARY KEY,
  summary    text,
  cvss       numeric(3,1),
  fetched_at timestamptz NOT NULL DEFAULT now()
);
