/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION arenadata_toolkit" to load this file. \quit

DO $$
BEGIN
	/*
	 For new deployments create arenadata_toolkit schema, but disconnect it from extension,
	 since user's tables like arenadata_toolkit.db_files_history need to be out of extension.
	 */
	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'arenadata_toolkit')
	THEN
		CREATE SCHEMA arenadata_toolkit;
		ALTER EXTENSION arenadata_toolkit DROP SCHEMA arenadata_toolkit;
	END IF;
END$$;

GRANT USAGE ON SCHEMA arenadata_toolkit TO public;

CREATE FUNCTION arenadata_toolkit.adb_relation_storage_size(reloid OID, forkName TEXT default 'main')
RETURNS BIGINT
AS '$libdir/arenadata_toolkit', 'adb_relation_storage_size'
LANGUAGE C VOLATILE STRICT;

GRANT EXECUTE ON FUNCTION arenadata_toolkit.adb_relation_storage_size(OID, TEXT) TO public;
COMMENT ON FUNCTION arenadata_toolkit.adb_relation_storage_size(OID, TEXT) IS 'Provides relation storage size details';

CREATE VIEW arenadata_toolkit.adb_skew_coefficients
AS
WITH storage AS (
    SELECT
        autoid,
        arenadata_toolkit.adb_relation_storage_size(autoid) AS size
    FROM gp_dist_random('gp_toolkit.__gp_user_tables')
    WHERE autrelstorage != 'x'
), skew AS (
    SELECT
        autoid AS skewoid,
        stddev(size) AS skewdev,
        avg(size) AS skewmean
    FROM storage GROUP BY autoid
)
SELECT
    skew.skewoid AS skcoid,
    pgn.nspname  AS skcnamespace,
    pgc.relname  AS skcrelname,
    CASE WHEN skewdev > 0 THEN skewdev/skewmean * 100.0 ELSE 0 END AS skccoeff
FROM skew
JOIN pg_catalog.pg_class pgc
    ON (skew.skewoid = pgc.oid)
JOIN pg_catalog.pg_namespace pgn
    ON (pgc.relnamespace = pgn.oid);

GRANT SELECT ON arenadata_toolkit.adb_skew_coefficients TO public;

/*
 This is part of arenadata_toolkit API for ADB Bundle.
 This function creates tables for performing adb_collect_table_stats.
 */
CREATE FUNCTION arenadata_toolkit.adb_create_tables()
RETURNS VOID
AS $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename  = 'db_files_history')
	THEN
		EXECUTE FORMAT($fmt$CREATE TABLE arenadata_toolkit.db_files_history(
			oid BIGINT,
			table_name TEXT,
			table_schema TEXT,
			type CHAR(1),
			storage CHAR(1),
			table_parent_table TEXT,
			table_parent_schema TEXT,
			table_database TEXT,
			table_tablespace TEXT,
			"content" INTEGER,
			segment_preferred_role CHAR(1),
			hostname TEXT,
			address TEXT,
			file TEXT,
			modifiedtime TIMESTAMP WITHOUT TIME ZONE,
			file_size BIGINT,
			collecttime TIMESTAMP WITHOUT TIME ZONE
		)
		WITH (appendonly=true, compresstype=zlib, compresslevel=9)
		DISTRIBUTED RANDOMLY
		PARTITION BY RANGE (collecttime)
		(
			PARTITION %1$I START (date %2$L) INCLUSIVE
			END (date %3$L) EXCLUSIVE
			EVERY (INTERVAL '1 month'),
			DEFAULT PARTITION default_part
		);$fmt$,
		'p' || to_char(NOW(), 'YYYYMM'),
		to_char(NOW(), 'YYYY-MM-01'),
		to_char(NOW() + interval '1 month','YYYY-MM-01'));

		/*
		 Only for admin usage.
		 */
		REVOKE ALL ON TABLE arenadata_toolkit.db_files_history FROM public;
	END IF;

	/*
	 The reason of not using CREATE TABLE IF NOT EXISTS statement, is that these tables
	 may exist from previous ADB installations. In theory there might be some custom user's grants
	 for these tables, so revoking them here may lead to a problems with an access.
	 For fresh new deployments we may set as we want.
	 */
	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename  = 'daily_operation')
	THEN
		CREATE TABLE arenadata_toolkit.daily_operation
		(
			schema_name TEXT,
			table_name TEXT,
			action TEXT,
			status TEXT,
			time BIGINT,
			processed_dttm TIMESTAMP
		)
		WITH (appendonly=true, compresstype=zlib, compresslevel=1)
		DISTRIBUTED RANDOMLY;

		/*
		 Only for admin usage.
		 */
		REVOKE ALL ON TABLE arenadata_toolkit.daily_operation FROM public;
	END IF;

	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename  = 'operation_exclude')
	THEN

		CREATE TABLE arenadata_toolkit.operation_exclude (schema_name TEXT)
		WITH (appendonly=true, compresstype=zlib, compresslevel=1)
		DISTRIBUTED RANDOMLY;

		/*
		 Only for admin usage.
		 */
		REVOKE ALL ON TABLE arenadata_toolkit.operation_exclude FROM public;

		INSERT INTO arenadata_toolkit.operation_exclude (schema_name)
		VALUES ('gp_toolkit'),
				('information_schema'),
				('pg_aoseg'),
				('pg_bitmapindex'),
				('pg_catalog'),
				('pg_toast');
	END IF;

	IF NOT EXISTS (SELECT 1 FROM pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename = 'db_files_current')
	THEN
		CREATE TABLE arenadata_toolkit.db_files_current
		(
			oid BIGINT,
			table_name TEXT,
			table_schema TEXT,
			type CHAR(1),
			storage CHAR(1),
			table_parent_table TEXT,
			table_parent_schema TEXT,
			table_database TEXT,
			table_tablespace TEXT,
			"content" INTEGER,
			segment_preferred_role CHAR(1),
			hostname TEXT,
			address TEXT,
			file TEXT,
			modifiedtime TIMESTAMP WITHOUT TIME ZONE,
			file_size BIGINT
		)
		WITH (appendonly = false) DISTRIBUTED RANDOMLY;
	END IF;

	GRANT SELECT ON TABLE arenadata_toolkit.db_files_current TO public;

	/*
	 We don't use this external web table in arenadata_toolkit extension.
	 collect_table_stats.sql deletes it in normal conditions,
	 but we drop it here as a double check.
	 */
	IF EXISTS (SELECT 1 FROM pg_tables
				WHERE schemaname = 'arenadata_toolkit' AND tablename = 'db_files')
	THEN
		DROP EXTERNAL TABLE arenadata_toolkit.db_files;
	END IF;
END$$
LANGUAGE plpgsql VOLATILE
EXECUTE ON MASTER;

/*
 Only for admin usage.
 */
REVOKE ALL ON FUNCTION arenadata_toolkit.adb_create_tables() FROM public;

CREATE FUNCTION arenadata_toolkit.adb_get_relfilenodes(tablespace_oid OID)
RETURNS TABLE (
	segindex INT2,
	dbid INT2,
	datoid OID,
	tablespace_oid OID,
	relfilepath TEXT,
	relfilenode OID,
	reloid OID,
	size BIGINT,
	modified_dttm TIMESTAMP WITHOUT TIME ZONE,
	changed_dttm TIMESTAMP WITHOUT TIME ZONE
)
EXECUTE ON ALL SEGMENTS
AS '$libdir/arenadata_toolkit', 'adb_get_relfilenodes'
LANGUAGE C STABLE STRICT;

GRANT EXECUTE ON FUNCTION arenadata_toolkit.adb_get_relfilenodes(OID)
	TO public;

CREATE VIEW arenadata_toolkit.__db_segment_files
AS
SELECT
	segfiles.segindex,
	segfiles.dbid,
	segfiles.datoid,
	segfiles.tablespace_oid,
	gpconf.datadir || '/' || relfilepath AS full_path,
	segfiles.size,
	segfiles.relfilenode,
	gpconf.preferred_role AS segment_preferred_role,
	gpconf.hostname AS hostname,
	gpconf.address AS address,
	segfiles.reloid,
	segfiles.modified_dttm,
	segfiles.changed_dttm
FROM pg_tablespace tbl, arenadata_toolkit.adb_get_relfilenodes(tbl.oid) AS segfiles
		 INNER JOIN gp_segment_configuration AS gpconf
					ON segfiles.dbid = gpconf.dbid;

GRANT SELECT ON arenadata_toolkit.__db_segment_files TO public;

CREATE VIEW arenadata_toolkit.__db_files_current
AS
SELECT
	c.oid AS oid,
	c.relname AS table_name,
	n.nspname AS table_schema,
	c.relkind AS type,
	c.relstorage AS storage,
	d.datname AS table_database,
	t.spcname AS table_tablespace,
	dbf.segindex AS content,
	dbf.segment_preferred_role AS segment_preferred_role,
	dbf.hostname AS hostname,
	dbf.address AS address,
	dbf.full_path AS file,
	dbf.size AS file_size,
	dbf.modified_dttm AS modifiedtime,
	dbf.changed_dttm AS changedtime
FROM arenadata_toolkit.__db_segment_files dbf
		 LEFT JOIN pg_class AS c
				   ON c.oid = dbf.reloid
		 LEFT JOIN pg_namespace n
				   ON c.relnamespace = n.oid
		 LEFT JOIN pg_tablespace t
				   ON dbf.tablespace_oid = t.oid
		 LEFT JOIN pg_database d
				   ON dbf.datoid = d.oid;

GRANT SELECT ON arenadata_toolkit.__db_files_current TO public;

CREATE VIEW arenadata_toolkit.__db_files_current_unmapped
AS
SELECT
	v.table_database,
	v.table_tablespace,
	v.content,
	v.segment_preferred_role,
	v.hostname,
	v.address,
	v.file,
	v.file_size
FROM arenadata_toolkit.__db_files_current v
WHERE v.oid IS NULL;

GRANT SELECT ON arenadata_toolkit.__db_files_current_unmapped TO public;

/*
 This is part of arenadata_toolkit API for ADB Bundle.
 This function collects information in db_files_current and db_files_history tables.
 */
CREATE FUNCTION arenadata_toolkit.adb_collect_table_stats()
RETURNS VOID
AS $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_partitions p
					WHERE
					p.schemaname = 'arenadata_toolkit'
					AND
					p.partitionschemaname = 'arenadata_toolkit'
					AND
					p.tablename = 'db_files_history'
					AND
					now() BETWEEN CAST(substring(partitionrangestart FROM '#"%#"::%' FOR '#') AS TIMESTAMP WITHOUT TIME ZONE)
					AND
					CAST(substring(partitionrangeend FROM '#"%#"::%' FOR '#') AS TIMESTAMP WITHOUT TIME ZONE)
					AND
					p.partitiontype = 'range'
					AND
					partitionstartinclusive = 't')
	THEN
		EXECUTE FORMAT($fmt$ALTER TABLE arenadata_toolkit.db_files_history SPLIT DEFAULT PARTITION
			START (date %1$L) INCLUSIVE
			END (date %2$L) EXCLUSIVE
			INTO (PARTITION %3$I, default partition);$fmt$,
				to_char(now(), 'YYYY-MM-01'),
				to_char(now() + interval '1 month','YYYY-MM-01'),
				'p'||to_char(now(), 'YYYYMM'));
	END IF;

	CREATE TEMPORARY TABLE IF NOT EXISTS db_files_current
	(
		oid BIGINT,
		table_name TEXT,
		table_schema TEXT,
		type CHAR(1),
		storage CHAR(1),
		table_parent_table TEXT,
		table_parent_schema TEXT,
		table_database TEXT,
		table_tablespace TEXT,
		"content" INTEGER,
		segment_preferred_role CHAR(1),
		hostname TEXT,
		address TEXT,
		file TEXT,
		modifiedtime TIMESTAMP WITHOUT TIME ZONE,
		file_size BIGINT
	)
	DISTRIBUTED RANDOMLY;

	/*
		Since this table is temporary and user can call this several times in a session
		then we need to truncate it (an alternative will be to drop it).
	 */
	TRUNCATE TABLE db_files_current;

	/* We use temporary table in this case, because we don't want to add own own unmapped
	   relfilenode oids in a db_files_current and db_files_history tables. The downside of
	   this approach that if time between calls to adb_collect_table_stats will be less
	   then checkpointing interval (there will be no unlink peformed), than these unmapped
	   files will still go to db_files_current and db_files_history as unmapped.
	*/
	INSERT INTO db_files_current
	SELECT
		f.oid,
		f.table_name,
		f.table_schema,
		f.type,
		f.storage,
		part.tablename AS table_parent_table,
		part.schemaname AS table_parent_schema,
		f.table_database,
		f.table_tablespace,
		f."content",
		f.segment_preferred_role,
		f.hostname,
		f.address,
		f.file,
		CURRENT_TIMESTAMP AS modifiedtime,
		f.file_size
	FROM arenadata_toolkit.__db_files_current AS f
	LEFT JOIN pg_partitions AS part
		ON (part.partitionschemaname = f.table_schema AND part.partitiontablename = f.table_name);

	/*
	 Here we may truncate it, it's relfilenodes aren't in db_files_current temporary table.
	 */
	TRUNCATE TABLE arenadata_toolkit.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_current
	SELECT *
	FROM db_files_current;

	INSERT INTO arenadata_toolkit.db_files_history
	SELECT *, now() AS collecttime
	FROM arenadata_toolkit.db_files_current;

END$$
LANGUAGE plpgsql VOLATILE
EXECUTE ON MASTER;

/*
	Only for admin usage.
 */
REVOKE ALL ON FUNCTION arenadata_toolkit.adb_collect_table_stats() FROM public;
/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.0--1.1.sql */

ALTER FUNCTION arenadata_toolkit.adb_get_relfilenodes(tablespace_oid OID) ROWS 30000000;

CREATE OR REPLACE FUNCTION arenadata_toolkit.adb_relation_storage_size_on_segments(
	IN reloid OID, IN forkName TEXT default 'main',
	OUT gp_segment_id INT, OUT size BIGINT)
AS 'SELECT pg_catalog.gp_execution_segment() AS gp_segment_id, *
	FROM arenadata_toolkit.adb_relation_storage_size($1, $2)'
LANGUAGE SQL EXECUTE ON ALL SEGMENTS;

GRANT EXECUTE ON FUNCTION arenadata_toolkit.adb_relation_storage_size_on_segments(OID, TEXT) TO public;

CREATE OR REPLACE VIEW arenadata_toolkit.adb_skew_coefficients
AS
WITH recursive cte AS (
	SELECT
		oid AS id,
		tables_size.gp_segment_id AS seg_id,
		tables_size.size AS size
	FROM pg_catalog.pg_class,
		 arenadata_toolkit.adb_relation_storage_size_on_segments(oid) AS tables_size
	WHERE relkind = 'r' AND relstorage != 'x' AND
		relnamespace IN (SELECT aunoid FROM gp_toolkit.__gp_user_namespaces)
	UNION ALL
	SELECT inhparent AS id, seg_id, size
	FROM cte
	LEFT JOIN pg_catalog.pg_inherits ON inhrelid = id
	WHERE inhparent != 0
), tables_size_by_segments AS (
	SELECT id, sum(size) AS size
	FROM cte
	GROUP BY id, seg_id
), skew AS (
	SELECT
		id AS skewoid,
		stddev(size) AS skewdev,
		avg(size) AS skewmean
	FROM tables_size_by_segments
	GROUP BY id
)
SELECT
	skew.skewoid AS skcoid,
	pgn.nspname  AS skcnamespace,
	pgc.relname  AS skcrelname,
	CASE WHEN skewdev > 0 THEN skewdev/skewmean * 100.0 ELSE 0 END AS skccoeff
FROM skew
JOIN pg_catalog.pg_class pgc ON (skew.skewoid = pgc.oid)
JOIN pg_catalog.pg_namespace pgn ON (pgc.relnamespace = pgn.oid);

GRANT SELECT ON arenadata_toolkit.adb_skew_coefficients TO public;
/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.1--1.2.sql */

/*
 This is part of arenadata_toolkit API for ADB Bundle.
 This function collects information in db_files_current and db_files_history tables.
 */
CREATE OR REPLACE FUNCTION arenadata_toolkit.adb_collect_table_stats()
RETURNS VOID
AS $$
BEGIN
	IF NOT EXISTS (
		SELECT 1
		FROM pg_partition pp
		JOIN pg_class cl1 ON pp.parrelid = cl1.oid
		JOIN pg_partition_rule pr ON pr.paroid = pp.oid
		JOIN pg_class cl2 ON cl2.oid = pr.parchildrelid
		JOIN pg_namespace n1 ON cl1.relnamespace = n1.oid
		JOIN pg_namespace n2 ON cl2.relnamespace = n2.oid
		WHERE
			pp.paristemplate = false
			AND
			n1.nspname = 'arenadata_toolkit'
			AND
			n2.nspname = 'arenadata_toolkit'
			AND
			cl1.relname = 'db_files_history'
			AND
			now() BETWEEN CAST(
				substring(pg_get_expr(pr.parrangestart, pr.parchildrelid) FROM '#"%#"::%' FOR '#')
				AS TIMESTAMP WITHOUT TIME ZONE)
			AND
			CAST(substring(pg_get_expr(pr.parrangeend, pr.parchildrelid) FROM '#"%#"::%' FOR '#')
				AS TIMESTAMP WITHOUT TIME ZONE)
			AND
			pp.parkind = 'r'  --range
			AND
			pr.parrangestartincl = 't')
	THEN
		EXECUTE FORMAT($fmt$ALTER TABLE arenadata_toolkit.db_files_history SPLIT DEFAULT PARTITION
			START (date %1$L) INCLUSIVE
			END (date %2$L) EXCLUSIVE
			INTO (PARTITION %3$I, default partition);$fmt$,
				to_char(now(), 'YYYY-MM-01'),
				to_char(now() + interval '1 month','YYYY-MM-01'),
				'p'||to_char(now(), 'YYYYMM'));
	END IF;

	CREATE TEMPORARY TABLE IF NOT EXISTS pg_temp.db_files_current
	(
		oid BIGINT,
		table_name TEXT,
		table_schema TEXT,
		type CHAR(1),
		storage CHAR(1),
		table_parent_table TEXT,
		table_parent_schema TEXT,
		table_database TEXT,
		table_tablespace TEXT,
		"content" INTEGER,
		segment_preferred_role CHAR(1),
		hostname TEXT,
		address TEXT,
		file TEXT,
		modifiedtime TIMESTAMP WITHOUT TIME ZONE,
		file_size BIGINT
	)
	DISTRIBUTED RANDOMLY;

	/*
		Since this table is temporary and user can call this several times in a session
		then we need to truncate it (an alternative will be to drop it).
	 */
	TRUNCATE TABLE pg_temp.db_files_current;

	/* We use temporary table in this case, because we don't want to add own own unmapped
	   relfilenode oids in a db_files_current and db_files_history tables. The downside of
	   this approach that if time between calls to adb_collect_table_stats will be less
	   then checkpointing interval (there will be no unlink peformed), than these unmapped
	   files will still go to db_files_current and db_files_history as unmapped.
	*/
	INSERT INTO pg_temp.db_files_current
	SELECT
		f.oid,
		f.table_name,
		f.table_schema,
		f.type,
		f.storage,
		cl.relname AS table_parent_table,
		n.nspname AS table_parent_schema,
		f.table_database,
		f.table_tablespace,
		f."content",
		f.segment_preferred_role,
		f.hostname,
		f.address,
		f.file,
		CURRENT_TIMESTAMP AS modifiedtime,
		f.file_size
	FROM arenadata_toolkit.__db_files_current AS f
	LEFT JOIN pg_partition_rule pr ON pr.parchildrelid = f.oid
	LEFT JOIN pg_partition pp ON pr.paroid = pp.oid
	LEFT JOIN pg_class cl ON cl.oid = pp.parrelid
	LEFT JOIN pg_namespace n ON cl.relnamespace = n.oid;

	/*
	 Here we may truncate it, it's relfilenodes aren't in db_files_current temporary table.
	 */
	TRUNCATE TABLE arenadata_toolkit.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_current
	SELECT *
	FROM pg_temp.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_history
	SELECT *, now() AS collecttime
	FROM arenadata_toolkit.db_files_current;
END$$
LANGUAGE plpgsql VOLATILE
EXECUTE ON MASTER;

/*
	Only for admin usage.
 */
REVOKE ALL ON FUNCTION arenadata_toolkit.adb_collect_table_stats() FROM public;
/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.2--1.3.sql */

/*
 * Returns columns (table_schema, table_name) ordered by increasing vacuum time. In this
 * list, if newest_first is true, then tables that are not yet vacuumed are located first,
 * and already vacuumed - at the end, else (newest_first is false) tables that are already
 * vacuumed are located first, and tables that are not yet vacuumed are located at the end.
 */
CREATE FUNCTION arenadata_toolkit.adb_vacuum_strategy(actionname TEXT, newest_first BOOLEAN)
RETURNS TABLE (table_schema NAME, table_name NAME) AS
$func$
BEGIN
	RETURN query EXECUTE format($$
	SELECT nspname, relname
	FROM pg_catalog.pg_class c
		JOIN pg_catalog.pg_namespace n ON relnamespace = n.oid
		LEFT JOIN pg_catalog.pg_partition_rule ON parchildrelid = c.oid
		LEFT JOIN pg_catalog.pg_stat_last_operation ON staactionname = UPPER(%L)
			AND objid = c.oid AND classid = 'pg_catalog.pg_class'::pg_catalog.regclass
	WHERE relkind = 'r' AND relstorage != 'x' AND parchildrelid IS NULL
		AND nspname NOT IN (SELECT schema_name FROM arenadata_toolkit.operation_exclude)
	ORDER BY statime ASC NULLS %s
	$$, actionname, CASE WHEN newest_first THEN 'FIRST' ELSE 'LAST' END);
END;
$func$ LANGUAGE plpgsql STABLE EXECUTE ON MASTER;

/*
 * Only for admin usage.
 */
REVOKE ALL ON FUNCTION arenadata_toolkit.adb_vacuum_strategy(TEXT, BOOLEAN) FROM public;

/*
 * Returns columns (table_schema, table_name) ordered by increasing vacuum time.
 * In this list, tables that are not yet vacuumed are located first,
 * and already vacuumed - at the end (default strategy).
 */
CREATE FUNCTION arenadata_toolkit.adb_vacuum_strategy_newest_first(actionname TEXT)
RETURNS TABLE (table_schema NAME, table_name NAME) AS
$$
	SELECT arenadata_toolkit.adb_vacuum_strategy(actionname, true);
$$ LANGUAGE sql STABLE EXECUTE ON MASTER;

/*
 * Only for admin usage.
 */
REVOKE ALL ON FUNCTION arenadata_toolkit.adb_vacuum_strategy_newest_first(TEXT) FROM public;

/*
 * Returns columns (table_schema, table_name) ordered by increasing vacuum time.
 * In this list, tables that are already vacuumed are located first,
 * and tables that are not yet vacuumed are located at the end.
 */
CREATE FUNCTION arenadata_toolkit.adb_vacuum_strategy_newest_last(actionname TEXT)
RETURNS TABLE (table_schema NAME, table_name NAME) AS
$$
	SELECT arenadata_toolkit.adb_vacuum_strategy(actionname, false);
$$ LANGUAGE sql STABLE EXECUTE ON MASTER;

/*
 * Only for admin usage.
 */
REVOKE ALL ON FUNCTION arenadata_toolkit.adb_vacuum_strategy_newest_last(TEXT) FROM public;
/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.3--1.4.sql */

DO $$
BEGIN
	IF a.attrelid IS NULL
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace AND
		                       n.nspname = 'arenadata_toolkit'
		LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND
		                            a.attname = 'tablespace_location'
		WHERE c.relname = 'db_files_current'
	THEN
		ALTER TABLE arenadata_toolkit.db_files_current
		ADD COLUMN tablespace_location TEXT;
	END IF;

	DROP TABLE IF EXISTS pg_temp.db_files_current;

	IF a.attrelid IS NULL
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace AND
		                       n.nspname = 'arenadata_toolkit'
		LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND
		                            a.attname = 'tablespace_location'
		WHERE c.relname = '__db_files_current'
	THEN
		CREATE OR REPLACE VIEW arenadata_toolkit.__db_files_current
		AS
		SELECT
			c.oid AS oid,
			c.relname AS table_name,
			n.nspname AS table_schema,
			c.relkind AS type,
			c.relstorage AS storage,
			d.datname AS table_database,
			t.spcname AS table_tablespace,
			dbf.segindex AS content,
			dbf.segment_preferred_role AS segment_preferred_role,
			dbf.hostname AS hostname,
			dbf.address AS address,
			dbf.full_path AS file,
			dbf.size AS file_size,
			dbf.modified_dttm AS modifiedtime,
			dbf.changed_dttm AS changedtime,
			CASE
				WHEN 'pg_default' = t.spcname THEN gpconf.datadir || '/base'
				WHEN 'pg_global' = t.spcname THEN gpconf.datadir || '/global'
				ELSE (SELECT tblspc_loc
					  FROM gp_tablespace_segment_location(t.oid)
					  WHERE gp_segment_id = dbf.segindex)
				END AS tablespace_location
		FROM arenadata_toolkit.__db_segment_files dbf
		LEFT JOIN pg_class c ON c.oid = dbf.reloid
		LEFT JOIN pg_namespace n ON c.relnamespace = n.oid
		LEFT JOIN pg_tablespace t ON dbf.tablespace_oid = t.oid
		LEFT JOIN pg_database d ON dbf.datoid = d.oid
		LEFT JOIN gp_segment_configuration gpconf ON dbf.dbid = gpconf.dbid;
	END IF;

	IF a.attrelid IS NULL
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace AND
		                       n.nspname = 'arenadata_toolkit'
		LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND
		                            a.attname = 'tablespace_location'
		WHERE c.relname = '__db_files_current_unmapped'
	THEN
		CREATE OR REPLACE VIEW arenadata_toolkit.__db_files_current_unmapped
		AS
		SELECT
			v.table_database,
			v.table_tablespace,
			v.content,
			v.segment_preferred_role,
			v.hostname,
			v.address,
			v.file,
			v.file_size,
			v.tablespace_location
		FROM arenadata_toolkit.__db_files_current v
		WHERE v.oid IS NULL;
	END IF;

	IF a.attrelid IS NULL
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace AND
		                       n.nspname = 'arenadata_toolkit'
		LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND
		                            a.attname = 'tablespace_location'
		WHERE c.relname = 'db_files_history'
	THEN
		EXECUTE FORMAT($fmt$ALTER TABLE arenadata_toolkit.db_files_history
							RENAME TO %1$I;$fmt$,
			to_char(now(), '"db_files_history_backup_"YYYYMMDD"t"HH24MISS'));
	END IF;
END $$;

/*
 This is part of arenadata_toolkit API for ADB Bundle.
 This function collects information in db_files_current and db_files_history tables.
 */
CREATE OR REPLACE FUNCTION arenadata_toolkit.adb_collect_table_stats()
RETURNS VOID
AS $$
BEGIN
	IF NOT EXISTS (
		SELECT
		FROM pg_partition pp
		JOIN pg_class cl1 ON pp.parrelid = cl1.oid
		JOIN pg_partition_rule pr ON pr.paroid = pp.oid
		JOIN pg_class cl2 ON cl2.oid = pr.parchildrelid
		JOIN pg_namespace n1 ON cl1.relnamespace = n1.oid
		JOIN pg_namespace n2 ON cl2.relnamespace = n2.oid
		WHERE
			pp.paristemplate = false
			AND
			n1.nspname = 'arenadata_toolkit'
			AND
			n2.nspname = 'arenadata_toolkit'
			AND
			cl1.relname = 'db_files_history'
			AND
			now() BETWEEN CAST(
				substring(pg_get_expr(pr.parrangestart, pr.parchildrelid) FROM '#"%#"::%' FOR '#')
				AS TIMESTAMP WITHOUT TIME ZONE)
			AND
			CAST(substring(pg_get_expr(pr.parrangeend, pr.parchildrelid) FROM '#"%#"::%' FOR '#')
				AS TIMESTAMP WITHOUT TIME ZONE)
			AND
			pp.parkind = 'r'  --range
			AND
			pr.parrangestartincl = 't')
	THEN
		EXECUTE FORMAT($fmt$ALTER TABLE arenadata_toolkit.db_files_history SPLIT DEFAULT PARTITION
			START (date %1$L) INCLUSIVE
			END (date %2$L) EXCLUSIVE
			INTO (PARTITION %3$I, default partition);$fmt$,
				to_char(now(), 'YYYY-MM-01'),
				to_char(now() + interval '1 month','YYYY-MM-01'),
				'p'||to_char(now(), 'YYYYMM'));
	END IF;

	CREATE TEMPORARY TABLE IF NOT EXISTS pg_temp.db_files_current
	(
		oid BIGINT,
		table_name TEXT,
		table_schema TEXT,
		type CHAR(1),
		storage CHAR(1),
		table_parent_table TEXT,
		table_parent_schema TEXT,
		table_database TEXT,
		table_tablespace TEXT,
		"content" INTEGER,
		segment_preferred_role CHAR(1),
		hostname TEXT,
		address TEXT,
		file TEXT,
		modifiedtime TIMESTAMP WITHOUT TIME ZONE,
		file_size BIGINT,
		tablespace_location TEXT
	)
	DISTRIBUTED RANDOMLY;

	/*
		Since this table is temporary and user can call this several times in a session
		then we need to truncate it (an alternative will be to drop it).
	 */
	TRUNCATE TABLE pg_temp.db_files_current;

	/* We use temporary table in this case, because we don't want to add own own unmapped
	   relfilenode oids in a db_files_current and db_files_history tables. The downside of
	   this approach that if time between calls to adb_collect_table_stats will be less
	   then checkpointing interval (there will be no unlink peformed), than these unmapped
	   files will still go to db_files_current and db_files_history as unmapped.
	*/
	INSERT INTO pg_temp.db_files_current
	SELECT
		f.oid,
		f.table_name,
		f.table_schema,
		f.type,
		f.storage,
		cl.relname AS table_parent_table,
		n.nspname AS table_parent_schema,
		f.table_database,
		f.table_tablespace,
		f."content",
		f.segment_preferred_role,
		f.hostname,
		f.address,
		f.file,
		CURRENT_TIMESTAMP AS modifiedtime,
		f.file_size,
		f.tablespace_location
	FROM arenadata_toolkit.__db_files_current AS f
	LEFT JOIN pg_partition_rule pr ON pr.parchildrelid = f.oid
	LEFT JOIN pg_partition pp ON pr.paroid = pp.oid
	LEFT JOIN pg_class cl ON cl.oid = pp.parrelid
	LEFT JOIN pg_namespace n ON cl.relnamespace = n.oid;

	/*
	 Here we may truncate it, it's relfilenodes aren't in db_files_current temporary table.
	 */
	TRUNCATE TABLE arenadata_toolkit.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_current
	SELECT *
	FROM pg_temp.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_history
	SELECT *, now() AS collecttime
	FROM arenadata_toolkit.db_files_current;
END$$
LANGUAGE plpgsql VOLATILE
EXECUTE ON MASTER;

/*
 This is part of arenadata_toolkit API for ADB Bundle.
 This function creates tables for performing adb_collect_table_stats.
 */
CREATE OR REPLACE FUNCTION arenadata_toolkit.adb_create_tables()
RETURNS VOID
AS $$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename  = 'db_files_history')
	THEN
		EXECUTE FORMAT($fmt$CREATE TABLE arenadata_toolkit.db_files_history(
			oid BIGINT,
			table_name TEXT,
			table_schema TEXT,
			type CHAR(1),
			storage CHAR(1),
			table_parent_table TEXT,
			table_parent_schema TEXT,
			table_database TEXT,
			table_tablespace TEXT,
			"content" INTEGER,
			segment_preferred_role CHAR(1),
			hostname TEXT,
			address TEXT,
			file TEXT,
			modifiedtime TIMESTAMP WITHOUT TIME ZONE,
			file_size BIGINT,
			tablespace_location TEXT,
			collecttime TIMESTAMP WITHOUT TIME ZONE
		)
		WITH (appendonly=true, compresstype=zlib, compresslevel=9)
		DISTRIBUTED RANDOMLY
		PARTITION BY RANGE (collecttime)
		(
			PARTITION %1$I START (date %2$L) INCLUSIVE
			END (date %3$L) EXCLUSIVE
			EVERY (INTERVAL '1 month'),
			DEFAULT PARTITION default_part
		);$fmt$,
		'p' || to_char(NOW(), 'YYYYMM'),
		to_char(NOW(), 'YYYY-MM-01'),
		to_char(NOW() + interval '1 month','YYYY-MM-01'));

		/*
		 Only for admin usage.
		 */
		REVOKE ALL ON TABLE arenadata_toolkit.db_files_history FROM public;
	END IF;

	/*
	 The reason of not using CREATE TABLE IF NOT EXISTS statement, is that these tables
	 may exist from previous ADB installations. In theory there might be some custom user's grants
	 for these tables, so revoking them here may lead to a problems with an access.
	 For fresh new deployments we may set as we want.
	 */
	IF NOT EXISTS (SELECT FROM pg_catalog.pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename  = 'daily_operation')
	THEN
		CREATE TABLE arenadata_toolkit.daily_operation
		(
			schema_name TEXT,
			table_name TEXT,
			action TEXT,
			status TEXT,
			time BIGINT,
			processed_dttm TIMESTAMP
		)
		WITH (appendonly=true, compresstype=zlib, compresslevel=1)
		DISTRIBUTED RANDOMLY;

		/*
		 Only for admin usage.
		 */
		REVOKE ALL ON TABLE arenadata_toolkit.daily_operation FROM public;
	END IF;

	IF NOT EXISTS (SELECT FROM pg_catalog.pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename  = 'operation_exclude')
	THEN

		CREATE TABLE arenadata_toolkit.operation_exclude (schema_name TEXT)
		WITH (appendonly=true, compresstype=zlib, compresslevel=1)
		DISTRIBUTED RANDOMLY;

		/*
		 Only for admin usage.
		 */
		REVOKE ALL ON TABLE arenadata_toolkit.operation_exclude FROM public;

		INSERT INTO arenadata_toolkit.operation_exclude (schema_name)
		VALUES ('gp_toolkit'),
				('information_schema'),
				('pg_aoseg'),
				('pg_bitmapindex'),
				('pg_catalog'),
				('pg_toast');
	END IF;

	IF NOT EXISTS (SELECT FROM pg_tables
					WHERE schemaname = 'arenadata_toolkit' AND tablename = 'db_files_current')
	THEN
		CREATE TABLE arenadata_toolkit.db_files_current
		(
			oid BIGINT,
			table_name TEXT,
			table_schema TEXT,
			type CHAR(1),
			storage CHAR(1),
			table_parent_table TEXT,
			table_parent_schema TEXT,
			table_database TEXT,
			table_tablespace TEXT,
			"content" INTEGER,
			segment_preferred_role CHAR(1),
			hostname TEXT,
			address TEXT,
			file TEXT,
			modifiedtime TIMESTAMP WITHOUT TIME ZONE,
			file_size BIGINT,
			tablespace_location TEXT
		)
		WITH (appendonly = false) DISTRIBUTED RANDOMLY;

		GRANT SELECT ON TABLE arenadata_toolkit.db_files_current TO public;
	END IF;

	/*
	 We don't use this external web table in arenadata_toolkit extension.
	 collect_table_stats.sql deletes it in normal conditions,
	 but we drop it here as a double check.
	 */
	IF EXISTS (SELECT FROM pg_tables
				WHERE schemaname = 'arenadata_toolkit' AND tablename = 'db_files')
	THEN
		DROP EXTERNAL TABLE arenadata_toolkit.db_files;
	END IF;
END$$
LANGUAGE plpgsql VOLATILE
EXECUTE ON MASTER;
/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.4--1.5.sql */

/*
 This is part of arenadata_toolkit API for ADB Bundle.
 This function collects information in db_files_current and db_files_history tables.
 */
CREATE OR REPLACE FUNCTION arenadata_toolkit.adb_collect_table_stats()
RETURNS VOID
AS $$
BEGIN
	IF NOT EXISTS (
		SELECT
		FROM pg_partition pp
		JOIN pg_partition_rule pr ON pr.paroid = pp.oid
		WHERE
			-- The filter on the line below, which duplicates condition in the 'case',
			-- is an optimization to fetch less tuples from the pg_partition.
			pp.parrelid = 'arenadata_toolkit.db_files_history'::regclass
			AND
			CASE
				WHEN pp.parrelid = 'arenadata_toolkit.db_files_history'::regclass
				THEN
					now() >= CAST(substring(pg_get_expr(pr.parrangestart, pr.parchildrelid) FROM '#"%#"::%' FOR '#')
						AS TIMESTAMP WITHOUT TIME ZONE)
					AND
					now() < CAST(substring(pg_get_expr(pr.parrangeend, pr.parchildrelid) FROM '#"%#"::%' FOR '#')
						AS TIMESTAMP WITHOUT TIME ZONE)
				ELSE FALSE
			END)
	THEN
		EXECUTE FORMAT($fmt$ALTER TABLE arenadata_toolkit.db_files_history SPLIT DEFAULT PARTITION
			START (date %1$L) INCLUSIVE
			END (date %2$L) EXCLUSIVE
			INTO (PARTITION %3$I, default partition);$fmt$,
				to_char(now(), 'YYYY-MM-01'),
				to_char(now() + interval '1 month','YYYY-MM-01'),
				'p'||to_char(now(), 'YYYYMM'));
	END IF;

	CREATE TEMPORARY TABLE IF NOT EXISTS pg_temp.db_files_current
	(
		oid BIGINT,
		table_name TEXT,
		table_schema TEXT,
		type CHAR(1),
		storage CHAR(1),
		table_parent_table TEXT,
		table_parent_schema TEXT,
		table_database TEXT,
		table_tablespace TEXT,
		"content" INTEGER,
		segment_preferred_role CHAR(1),
		hostname TEXT,
		address TEXT,
		file TEXT,
		modifiedtime TIMESTAMP WITHOUT TIME ZONE,
		file_size BIGINT,
		tablespace_location TEXT
	)
	DISTRIBUTED RANDOMLY;

	/*
		Since this table is temporary and user can call this several times in a session
		then we need to truncate it (an alternative will be to drop it).
	 */
	TRUNCATE TABLE pg_temp.db_files_current;

	/* We use temporary table in this case, because we don't want to add own own unmapped
	   relfilenode oids in a db_files_current and db_files_history tables. The downside of
	   this approach that if time between calls to adb_collect_table_stats will be less
	   then checkpointing interval (there will be no unlink peformed), than these unmapped
	   files will still go to db_files_current and db_files_history as unmapped.
	*/
	INSERT INTO pg_temp.db_files_current
	SELECT
		f.oid,
		f.table_name,
		f.table_schema,
		f.type,
		f.storage,
		cl.relname AS table_parent_table,
		n.nspname AS table_parent_schema,
		f.table_database,
		f.table_tablespace,
		f."content",
		f.segment_preferred_role,
		f.hostname,
		f.address,
		f.file,
		CURRENT_TIMESTAMP AS modifiedtime,
		f.file_size,
		f.tablespace_location
	FROM arenadata_toolkit.__db_files_current AS f
	LEFT JOIN pg_partition_rule pr ON pr.parchildrelid = f.oid
	LEFT JOIN pg_partition pp ON pr.paroid = pp.oid
	LEFT JOIN pg_class cl ON cl.oid = pp.parrelid
	LEFT JOIN pg_namespace n ON cl.relnamespace = n.oid;

	/*
	 Here we may truncate it, it's relfilenodes aren't in db_files_current temporary table.
	 */
	TRUNCATE TABLE arenadata_toolkit.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_current
	SELECT *
	FROM pg_temp.db_files_current;

	INSERT INTO arenadata_toolkit.db_files_history
	SELECT *, now() AS collecttime
	FROM arenadata_toolkit.db_files_current;
END$$
LANGUAGE plpgsql VOLATILE
EXECUTE ON MASTER;
/* gpcontrib/arenadata_toolkit/arenadata_toolkit--1.5--1.6.sql */

CREATE FUNCTION arenadata_toolkit.adb_hba_file_rules() RETURNS TABLE (
    line_number int4,
    type text,
    database text[],
    user_name text[],
    address text,
    netmask text,
    auth_method text,
    options text[],
    error text
) AS '$libdir/arenadata_toolkit', 'adb_hba_file_rules' LANGUAGE C VOLATILE STRICT;

CREATE VIEW arenadata_toolkit.adb_hba_file_rules_view AS
    SELECT * FROM arenadata_toolkit.adb_hba_file_rules();

REVOKE ALL on arenadata_toolkit.adb_hba_file_rules_view FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION arenadata_toolkit.adb_hba_file_rules() FROM PUBLIC;
