EXTENSION = pg_index_steward
MODULE_big = pg_index_steward
OBJS = src/steward.o
DATA = sql/pg_index_steward--0.1.0.sql
PGFILEDESC = "PG Index Steward - workload-aware index management"
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
