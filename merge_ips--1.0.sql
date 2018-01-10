/* merge_ips--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION merge_ips" to load this file. \quit

CREATE FUNCTION @extschema@.merge_ips(a_input inet[])
RETURNS TABLE (out_ip inet)
LANGUAGE plpgsql
AS $$

BEGIN

-- Turn the input array into a "work table".
CREATE TEMP TABLE IF NOT EXISTS work(ip inet) ON COMMIT DROP;
TRUNCATE TABLE work;
INSERT INTO work(ip)
SELECT ip
FROM   UNNEST(a_input) AS u(ip);

-- Auxiliary table to merge 2 adjacent IPs into one whith the prefix 1 bit
-- shorter.
CREATE TEMP TABLE IF NOT EXISTS pairs(ip inet, children inet[])
ON COMMIT DROP;
TRUNCATE TABLE pairs;

LOOP
	-- If any two (adjacent) subnets can form a new subnet whose mask is 1
	-- bit shorter, create a new row for it in "subnets".
	INSERT INTO pairs(ip, children)
	-- Cast to cidr is essential because --- for the aggregation sake ---
	-- we need to reset the bits not covered by the prefix. (We can't use
	-- cidr in the table definition because there seem to be no opclasses
	-- for indexing.)
        SELECT          set_masklen(w.ip::cidr, masklen(w.ip) - 1),
                        array_agg(DISTINCT w.ip)
        FROM            work AS w
        GROUP BY        1
	HAVING count(DISTINCT w.ip) = 2;

	-- Done if no more pairs could be found.
	IF NOT FOUND THEN
		EXIT;
	END IF;

	-- The new version of the work table will not contain the IPs which
	-- have just formed 2-member subnets.
	CREATE TEMP TABLE work_new ON COMMIT DROP AS
		SELECT ip
		FROM work WHERE ip NOT IN (
			SELECT	DISTINCT u.ip
			FROM	pairs p, UNNEST(p.children) u(ip));

	-- Replace those removed IPs with their newly-formed 2-member parents.
	INSERT INTO work_new(ip)
	SELECT ip
	FROM	pairs;

	-- Replace the original work table with the new one.
	DROP TABLE work;
	ALTER TABLE work_new RENAME TO work;

	-- Cleanup.
	TRUNCATE TABLE pairs;
END LOOP;

	-- Generate the output.
	--
	-- The requirement is that no pair of output IPs should exists such
	-- that one IP is contained by the other, even if the containing
	-- subnet should have gaps.
	--
	-- Also eliminate duplicate IPs which could be present in the input
	-- set (and which could not be merged into a subnet).
	RETURN QUERY
	SELECT DISTINCT ip
	FROM work w
	WHERE ip NOT IN (
                SELECT  w1.ip
                FROM    work AS w1
                        JOIN
                        work AS w2 ON w1.ip << w2.ip);
END;
$$;


CREATE FUNCTION @extschema@.merge_ips_array(a_input inet[])
RETURNS inet[]
LANGUAGE sql
AS $$

SELECT array_agg(ip)
FROM @extschema@.merge_ips(a_input) AS m(ip);
$$;
