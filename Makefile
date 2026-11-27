EXTENSION = pg_index_steward
MODULE_big = pg_index_steward
OBJS = src/steward.o
DATA = $(wildcard sql/pg_index_steward--*.sql)
PGFILEDESC = "PG Index Steward - workload-aware index management"
PG_CONFIG ?= pg_config
override enable_rpath = no
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
