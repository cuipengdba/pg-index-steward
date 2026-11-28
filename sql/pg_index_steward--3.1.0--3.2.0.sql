ALTER TABLE index_steward.timescale_compatibility ADD COLUMN coverage_mode text NOT NULL DEFAULT 'catalog'
    CHECK (coverage_mode IN ('catalog','definition'));
ALTER TABLE index_steward.timescale_compatibility ADD COLUMN experimental boolean NOT NULL DEFAULT false;
ALTER TABLE index_steward.policy ADD COLUMN timescale_experimental boolean NOT NULL DEFAULT false;
INSERT INTO index_steward.timescale_compatibility(pg_major,extension_version,coverage_mode,experimental) VALUES
  (14,'2.19.3','catalog',false),(15,'2.19.3','catalog',false),
  (16,'2.32.1','definition',false),(17,'2.32.1','definition',false),
  (18,'2.32.1','definition',false),(19,'2.32.1','definition',true);
