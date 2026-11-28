#include "postgres.h"
#include "commands/dbcommands.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "nodes/parsenodes.h"
#include "parser/parser.h"
#include "storage/lmgr.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/json.h"
#include "utils/lsyscache.h"

extern void steward_hypopg_init(void);
extern Datum hypopg_create_index(PG_FUNCTION_ARGS);
extern Datum hypopg_reset(PG_FUNCTION_ARGS);
static bool steward_hypo_initialized = false;

PG_FUNCTION_INFO_V1(steward_lock_index);
Datum
steward_lock_index(PG_FUNCTION_ARGS)
{
	LockRelationOid(PG_GETARG_OID(0), AccessExclusiveLock);
	PG_RETURN_VOID();
}

#if PG_VERSION_NUM >= 190000
PG_MODULE_MAGIC_EXT(.name = "pg_index_steward", .version = "3.11.0");
#else
PG_MODULE_MAGIC;
#endif

static bool auto_create;
static bool auto_drop_existing;
static bool auto_drop_managed;
static char *maintenance_window;

static bool
valid_window(char **value, void **extra, GucSource source)
{
	const char *s = *value;
	int positions[] = {0, 1, 3, 4, 6, 7, 9, 10};
	int i;

	if (s == NULL || strlen(s) != 11 || s[2] != ':' || s[5] != '-' || s[8] != ':')
		return false;
	for (i = 0; i < lengthof(positions); i++)
		if (s[positions[i]] < '0' || s[positions[i]] > '9')
			return false;
	return 10 * (s[0] - '0') + (s[1] - '0') < 24 && s[3] < '6' &&
		10 * (s[6] - '0') + (s[7] - '0') < 24 && s[9] < '6' &&
		strncmp(s, s + 6, 5) != 0;
}

void _PG_init(void);
void
_PG_init(void)
{
	DefineCustomBoolVariable("pg_index_steward.auto_create", "Create eligible indexes in the maintenance window.", NULL,
							 &auto_create, true, PGC_SIGHUP, 0, NULL, NULL, NULL);
	DefineCustomStringVariable("pg_index_steward.maintenance_window", "Maintenance window in the server's configured time zone.", NULL,
							   &maintenance_window, "23:00-06:00", PGC_SIGHUP, 0, valid_window, NULL, NULL);
	DefineCustomBoolVariable("pg_index_steward.auto_drop_existing", "Retire eligible pre-existing non-unique indexes.", NULL,
							 &auto_drop_existing, false, PGC_SIGHUP, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("pg_index_steward.auto_drop_managed", "Retire eligible indexes created by Steward.", NULL,
							 &auto_drop_managed, true, PGC_SIGHUP, 0, NULL, NULL, NULL);
}

typedef struct Predicates
{
	const char *alias;
	const char *relation;
	const char *eq[8];
	const char *range;
	int n_eq;
	bool ambiguous_range;
} Predicates;

static const char *
column_name(Node *node, const Predicates *pred)
{
	ColumnRef *ref;
	Node *last;

	if (node == NULL || !IsA(node, ColumnRef))
		return NULL;
	ref = (ColumnRef *) node;
	if (list_length(ref->fields) == 2)
	{
		Node *first = linitial(ref->fields);
		const char *qualifier = pred->alias ? pred->alias : pred->relation;

		if (!IsA(first, String) || strcmp(strVal(first), qualifier) != 0)
			return NULL;
	}
	else if (list_length(ref->fields) != 1)
		return NULL;
	last = llast(ref->fields);
	return IsA(last, String) ? strVal(last) : NULL;
}

static bool
bound_value(Node *node)
{
	return node != NULL && (IsA(node, ParamRef) || IsA(node, A_Const));
}

static void
collect(Node *node, Predicates *pred)
{
	A_Expr *expr;
	const char *col = NULL;
	const char *op;
	bool equality = false;
	int i;

	if (node == NULL)
		return;
	if (IsA(node, BoolExpr))
	{
		BoolExpr *b = (BoolExpr *) node;
		ListCell *cell;

		if (b->boolop == AND_EXPR)
			foreach(cell, b->args)
				collect(lfirst(cell), pred);
		return;
	}
	if (!IsA(node, A_Expr))
		return;
	expr = (A_Expr *) node;
	if (list_length(expr->name) != 1 || !IsA(linitial(expr->name), String))
		return;
	op = strVal(linitial(expr->name));
	if (expr->kind == AEXPR_IN && strcmp(op, "=") == 0 && expr->rexpr != NULL && IsA(expr->rexpr, List))
	{
		ListCell *item;
		List *values = (List *) expr->rexpr;

		if (list_length(values) > 16)
			return;
		foreach(item, values)
			if (!bound_value(lfirst(item)))
				return;
		col = column_name(expr->lexpr, pred);
		equality = true;
	}
	else if (expr->kind == AEXPR_OP)
	{
		equality = strcmp(op, "=") == 0;
		if (!equality && strcmp(op, ">") && strcmp(op, ">=") && strcmp(op, "<") && strcmp(op, "<="))
			return;
		if (bound_value(expr->rexpr))
			col = column_name(expr->lexpr, pred);
		else if (bound_value(expr->lexpr))
			col = column_name(expr->rexpr, pred);
	}
	if (!col)
		return;
	if (!equality)
	{
		if (pred->range && strcmp(col, pred->range) != 0)
			pred->ambiguous_range = true;
		pred->range = col;
		return;
	}
	for (i = 0; i < pred->n_eq; i++)
		if (strcmp(col, pred->eq[i]) == 0)
			return;
	if (pred->n_eq < lengthof(pred->eq))
		pred->eq[pred->n_eq++] = col;
}

static void
append_advisory(RangeVar *rel, const char *key, StringInfo result, bool *first)
{
	if (!key || !rel->schemaname || rel->catalogname)
		return;
	if (!*first)
		appendStringInfoChar(result, ',');
	*first = false;
	appendStringInfoString(result, "{\"schema\":");
	escape_json(result, rel->schemaname);
	appendStringInfoString(result, ",\"table\":");
	escape_json(result, rel->relname);
	appendStringInfoString(result, ",\"eq\":[");
	escape_json(result, key);
	appendStringInfoString(result, "],\"range\":null,\"advisory\":true}");
}

static void
select_candidates(SelectStmt *stmt, StringInfo result, bool *first)
{
	RangeVar *rel;
	Predicates pred = {0};
	int i;

	if (stmt->withClause || stmt->intoClause || stmt->lockingClause)
		return;
	if (stmt->op == SETOP_UNION)
	{
		select_candidates(stmt->larg, result, first);
		select_candidates(stmt->rarg, result, first);
		return;
	}
	if (stmt->op != SETOP_NONE || list_length(stmt->fromClause) != 1)
		return;
	if (IsA(linitial(stmt->fromClause), JoinExpr))
	{
		JoinExpr *join = linitial_node(JoinExpr, stmt->fromClause);
		if (IsA(join->larg, RangeVar) && IsA(join->rarg, RangeVar) && IsA(join->quals, A_Expr))
		{
			RangeVar *left = (RangeVar *) join->larg;
			RangeVar *right = (RangeVar *) join->rarg;
			A_Expr *expr = (A_Expr *) join->quals;
			Predicates a = {0}, b = {0};
			if (expr->kind != AEXPR_OP || list_length(expr->name) != 1 ||
				strcmp(strVal(linitial(expr->name)), "=") ||
				!IsA(expr->lexpr, ColumnRef) || !IsA(expr->rexpr, ColumnRef) ||
				list_length(((ColumnRef *) expr->lexpr)->fields) != 2 ||
				list_length(((ColumnRef *) expr->rexpr)->fields) != 2)
				return;
			a.relation = left->relname;
			a.alias = left->alias ? left->alias->aliasname : NULL;
			b.relation = right->relname;
			b.alias = right->alias ? right->alias->aliasname : NULL;
			append_advisory(left, column_name(expr->lexpr, &a), result, first);
			append_advisory(left, column_name(expr->rexpr, &a), result, first);
			append_advisory(right, column_name(expr->lexpr, &b), result, first);
			append_advisory(right, column_name(expr->rexpr, &b), result, first);
		}
		return;
	}
	if (!IsA(linitial(stmt->fromClause), RangeVar))
		return;
	rel = linitial_node(RangeVar, stmt->fromClause);
	if (rel->catalogname || !rel->schemaname)
		return;
	pred.alias = rel->alias ? rel->alias->aliasname : NULL;
	pred.relation = rel->relname;
	collect(stmt->whereClause, &pred);
	if (pred.n_eq == 0 && (!pred.range || pred.ambiguous_range))
	{
		if (stmt->limitCount && list_length(stmt->sortClause) == 1 && !stmt->groupClause && !stmt->distinctClause)
		{
			SortBy *sort = linitial_node(SortBy, stmt->sortClause);
			if (sort->sortby_dir != SORTBY_USING)
				append_advisory(rel, column_name(sort->node, &pred), result, first);
		}
		return;
	}
	if (!*first)
		appendStringInfoChar(result, ',');
	*first = false;
	appendStringInfoString(result, "{\"schema\":");
	escape_json(result, rel->schemaname);
	appendStringInfoString(result, ",\"table\":");
	escape_json(result, rel->relname);
	appendStringInfoString(result, ",\"eq\":[");
	for (i = 0; i < pred.n_eq; i++)
	{
		if (i)
			appendStringInfoChar(result, ',');
		escape_json(result, pred.eq[i]);
	}
	appendStringInfoString(result, "],\"range\":");
	if (pred.range && !pred.ambiguous_range)
		escape_json(result, pred.range);
	else
		appendStringInfoString(result, "null");
	appendStringInfoChar(result, '}');
}

PG_FUNCTION_INFO_V1(steward_candidates);
Datum
steward_candidates(PG_FUNCTION_ARGS)
{
	text *sql = PG_GETARG_TEXT_PP(0);
	StringInfoData result;
	bool first = true;
	List *list;

	initStringInfo(&result);
	appendStringInfoChar(&result, '[');
	if (VARSIZE_ANY_EXHDR(sql) <= 16384)
	{
		list = raw_parser(text_to_cstring(sql), RAW_PARSE_DEFAULT);
		if (list_length(list) == 1)
		{
			RawStmt *raw = linitial_node(RawStmt, list);

			if (IsA(raw->stmt, SelectStmt))
				select_candidates((SelectStmt *) raw->stmt, &result, &first);
		}
	}
	appendStringInfoChar(&result, ']');
	PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(result.data)));
}

PG_FUNCTION_INFO_V1(steward_log_event);
Datum
steward_log_event(PG_FUNCTION_ARGS)
{
	StringInfoData payload;
	const char *database = get_database_name(MyDatabaseId);
	const char *keys[] = {"event", "action", "reason", "retry_at"};
	const int args[] = {0, 2, 3, 4};
	int i;

	initStringInfo(&payload);
	appendStringInfoString(&payload, "{\"database\":");
	escape_json(&payload, database ? database : "unknown");
	if (!PG_ARGISNULL(1))
		appendStringInfo(&payload, ",\"job_id\":" INT64_FORMAT, PG_GETARG_INT64(1));
	for (i = 0; i < lengthof(args); i++)
	{
		if (PG_ARGISNULL(args[i]))
			continue;
		appendStringInfo(&payload, ",\"%s\":", keys[i]);
		escape_json(&payload, text_to_cstring(PG_GETARG_TEXT_PP(args[i])));
	}
	appendStringInfoChar(&payload, '}');
	ereport(LOG, (errmsg_internal("PG Index Steward %s", payload.data), errhidestmt(true)));
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(steward_hypo_create);
PG_FUNCTION_INFO_V1(steward_valid_plan_sample);
Datum
steward_valid_plan_sample(PG_FUNCTION_ARGS)
{
	List *statements = raw_parser(text_to_cstring(PG_GETARG_TEXT_PP(0)), RAW_PARSE_DEFAULT);
	Node *node;
	SelectStmt *stmt;
	if (list_length(statements) != 1)
		PG_RETURN_BOOL(false);
	node = linitial_node(RawStmt, statements)->stmt;
	if (!IsA(node, SelectStmt))
		PG_RETURN_BOOL(false);
	stmt = (SelectStmt *) node;
	PG_RETURN_BOOL(stmt->withClause == NULL && stmt->intoClause == NULL &&
				   stmt->lockingClause == NIL && stmt->op == SETOP_NONE);
}

Datum
steward_hypo_create(PG_FUNCTION_ARGS)
{
	if (!steward_hypo_initialized)
	{
		steward_hypopg_init();
		steward_hypo_initialized = true;
	}
	return hypopg_create_index(fcinfo);
}

PG_FUNCTION_INFO_V1(steward_hypo_reset);
Datum
steward_hypo_reset(PG_FUNCTION_ARGS)
{
	if (!steward_hypo_initialized)
		PG_RETURN_VOID();
	return hypopg_reset(fcinfo);
}
