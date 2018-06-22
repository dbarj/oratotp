WHENEVER SQLERROR EXIT SQL.SQLCODE

SET DEFINE ON

ALTER SESSION SET CURRENT_SCHEMA=&_vUsername
/

SET DEFINE OFF

CREATE OR REPLACE PACKAGE TWOFACTOR_INTERNAL AS
  /************************************************************************

   OraTOtP - Oracle Time-based One-time Password
   Copyright 2016  Rodrigo Jorge <http://www.dbarj.com.br/>

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

  ************************************************************************/
  -- Code Gen
  TYPE CODEROW IS RECORD(
    CODE VARCHAR2(6 CHAR)); --Only to give column a name
  TYPE CODES IS TABLE OF CODEROW;
  FUNCTION CODEGEN(PSECRET IN VARCHAR2, PGAP IN NUMBER) RETURN CODES
    PIPELINED;
  -- Support Functions
  FUNCTION URLGEN(PUSER IN VARCHAR2, PPASS IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;
  FUNCTION CODECHECK(PUSER IN VARCHAR2, PCODE IN VARCHAR2, PPASS IN VARCHAR2 DEFAULT NULL) RETURN BOOLEAN;
  -- Sets
  PROCEDURE SETSTATUS(PUSER IN VARCHAR2, PSTATUS IN VARCHAR2);
  PROCEDURE SETVALIDATED(PUSER IN VARCHAR2);
  PROCEDURE SETAUTHENTICATED;
  -- Manipulate
  PROCEDURE ADDUSER(PUSER IN VARCHAR2, PGAP IN NUMBER DEFAULT NULL, PPASS IN VARCHAR2 DEFAULT NULL);
  PROCEDURE REMUSER(PUSER IN VARCHAR2);
  PROCEDURE CLEANMEMORY(PUSER IN VARCHAR2);
  FUNCTION ADDMEMORY(PUSER IN VARCHAR2, PINT IN INTERVAL DAY TO SECOND DEFAULT INTERVAL '7' DAY) RETURN BOOLEAN;
  -- Checks
  FUNCTION ISUSERSETUP(PUSER IN VARCHAR2) RETURN BOOLEAN;
  FUNCTION ISUSERENABLED(PUSER IN VARCHAR2) RETURN BOOLEAN;
  FUNCTION ISUSERVALIDATED(PUSER IN VARCHAR2) RETURN BOOLEAN;
  -- Login Refresh
  PROCEDURE CHECKANDAUTHUSER;
END TWOFACTOR_INTERNAL;
/

CREATE OR REPLACE PACKAGE BODY TWOFACTOR_INTERNAL AS
  /************************************************************************

   OraTOtP - Oracle Time-based One-time Password
   Copyright 2016  Rodrigo Jorge <http://www.dbarj.com.br/>

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

  ************************************************************************/
  CBASE32             CONSTANT VARCHAR2(32 CHAR) := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  DEFAULT_SECRET_PASS CONSTANT VARCHAR2(30 CHAR) := 'DBA-RJ'; -- If changed, any generated Key w/o password may stop working.

  FUNCTION ENCKEY(PDEC IN VARCHAR2, PPASS IN VARCHAR2) RETURN RAW IS
    L_SEC_RAW       RAW(16) := UTL_RAW.CAST_TO_RAW(PDEC); -- Key size = 16 characters = 16 bytes
    L_PASS_RAW      RAW(30) := UTL_RAW.CAST_TO_RAW(PPASS); -- Pass size = Max 30 characters = 30 bytes
    L_HASH_KEY      RAW(20); -- SHA1 = 160 bits = 20 bytes
    L_ENCRYPTED_RAW RAW(24); -- FACKEYS.KEY%TYPE does not work for INVISIBLE cols
  BEGIN
    -- Target is not to protect, just make it not obvious
    L_HASH_KEY      := DBMS_CRYPTO.HASH(L_PASS_RAW, DBMS_CRYPTO.HASH_SH1);
    L_ENCRYPTED_RAW := DBMS_CRYPTO.ENCRYPT(L_SEC_RAW, DBMS_CRYPTO.DES_CBC_PKCS5, L_HASH_KEY);
    RETURN L_ENCRYPTED_RAW;
  END ENCKEY;

  FUNCTION DECKEY(PENC IN RAW, PPASS IN VARCHAR2) RETURN VARCHAR2 IS
    L_PASS_RAW        RAW(30) := UTL_RAW.CAST_TO_RAW(PPASS); -- Pass size = Max 30 characters = 30 bytes
    L_HASH_KEY        RAW(20); -- SHA1 = 160 bits = 20 bytes
    L_UNENCRYPTED_RAW RAW(16); -- Key size = 16 characters = 16 bytes
  BEGIN
    -- Target is not to protect, just make it not obvious
    L_HASH_KEY        := DBMS_CRYPTO.HASH(L_PASS_RAW, DBMS_CRYPTO.HASH_SH1);
    L_UNENCRYPTED_RAW := DBMS_CRYPTO.DECRYPT(PENC, DBMS_CRYPTO.DES_CBC_PKCS5, L_HASH_KEY);
    RETURN UTL_RAW.CAST_TO_VARCHAR2(L_UNENCRYPTED_RAW);
  END DECKEY;

  FUNCTION REPLACEINENCSTR(PSRCSTR IN VARCHAR2, POLDSUB IN VARCHAR2, PNEWSUB IN VARCHAR2) RETURN VARCHAR2 IS
    VSTRNOHEXA VARCHAR2(2000 CHAR) := REGEXP_REPLACE(PSRCSTR, '%[[:xdigit:]]{2}', '---');
    VNTH       NUMBER := 1;
    VPOS       NUMBER := 1;
    VOUTPUT    VARCHAR2(2000 CHAR) := PSRCSTR;
  BEGIN
    WHILE VPOS <> 0
    LOOP
      VPOS := INSTR(VSTRNOHEXA, POLDSUB, 1, VNTH);
      IF VPOS <> 0
      THEN
        VOUTPUT := SUBSTR(VOUTPUT, 1, VPOS - 1 + ((LENGTH(PNEWSUB) - 1) * (VNTH - 1))) || PNEWSUB || SUBSTR(VOUTPUT, VPOS + 1 + ((LENGTH(PNEWSUB) - 1) * (VNTH - 1)));
        VNTH    := VNTH + 1;
      END IF;
    END LOOP;
    RETURN VOUTPUT;
  END REPLACEINENCSTR;

  FUNCTION CONVURLENCODE(PSTR IN VARCHAR2) RETURN VARCHAR2 IS
    VSTR VARCHAR2(2000 CHAR) := PSTR;
  BEGIN
    -- Need to come first
    VSTR := REPLACE(VSTR, ' ', '%20');
    VSTR := REPLACE(VSTR, '!', '%21');
    VSTR := REPLACE(VSTR, '"', '%22');
    VSTR := REPLACE(VSTR, '#', '%23');
    VSTR := REPLACE(VSTR, '$', '%24');
    VSTR := REPLACEINENCSTR(VSTR, '%', '%25'); -- To avoid replacing already encoded chars
    VSTR := REPLACE(VSTR, '&', '%26');
    VSTR := REPLACE(VSTR, '''', '%27');
    VSTR := REPLACE(VSTR, '(', '%28');
    VSTR := REPLACE(VSTR, ')', '%29');
    VSTR := REPLACE(VSTR, '*', '%2A');
    VSTR := REPLACE(VSTR, '+', '%2B');
    VSTR := REPLACE(VSTR, ',', '%2C');
    VSTR := REPLACE(VSTR, '-', '%2D');
    VSTR := REPLACE(VSTR, '.', '%2E');
    VSTR := REPLACE(VSTR, '/', '%2F');
    VSTR := REPLACEINENCSTR(VSTR, '0', '%30'); -- To avoid replacing already encoded chars
    VSTR := REPLACEINENCSTR(VSTR, '1', '%31');
    VSTR := REPLACEINENCSTR(VSTR, '2', '%32');
    VSTR := REPLACEINENCSTR(VSTR, '3', '%33');
    VSTR := REPLACEINENCSTR(VSTR, '4', '%34');
    VSTR := REPLACEINENCSTR(VSTR, '5', '%35');
    VSTR := REPLACEINENCSTR(VSTR, '6', '%36');
    VSTR := REPLACEINENCSTR(VSTR, '7', '%37');
    VSTR := REPLACEINENCSTR(VSTR, '8', '%38');
    VSTR := REPLACEINENCSTR(VSTR, '9', '%39');
    VSTR := REPLACE(VSTR, ':', '%3A');
    VSTR := REPLACE(VSTR, ';', '%3B');
    VSTR := REPLACE(VSTR, '<', '%3C');
    VSTR := REPLACE(VSTR, '=', '%3D');
    VSTR := REPLACE(VSTR, '>', '%3E');
    VSTR := REPLACE(VSTR, '?', '%3F');
    VSTR := REPLACE(VSTR, '@', '%40');
    VSTR := REPLACEINENCSTR(VSTR, 'A', '%41'); -- To avoid replacing already encoded chars
    VSTR := REPLACEINENCSTR(VSTR, 'B', '%42');
    VSTR := REPLACEINENCSTR(VSTR, 'C', '%43');
    VSTR := REPLACEINENCSTR(VSTR, 'D', '%44');
    VSTR := REPLACEINENCSTR(VSTR, 'E', '%45');
    VSTR := REPLACEINENCSTR(VSTR, 'F', '%46');
    VSTR := REPLACE(VSTR, 'G', '%47');
    VSTR := REPLACE(VSTR, 'H', '%48');
    VSTR := REPLACE(VSTR, 'I', '%49');
    VSTR := REPLACE(VSTR, 'J', '%4A');
    VSTR := REPLACE(VSTR, 'K', '%4B');
    VSTR := REPLACE(VSTR, 'L', '%4C');
    VSTR := REPLACE(VSTR, 'M', '%4D');
    VSTR := REPLACE(VSTR, 'N', '%4E');
    VSTR := REPLACE(VSTR, 'O', '%4F');
    VSTR := REPLACE(VSTR, 'P', '%50');
    VSTR := REPLACE(VSTR, 'Q', '%51');
    VSTR := REPLACE(VSTR, 'R', '%52');
    VSTR := REPLACE(VSTR, 'S', '%53');
    VSTR := REPLACE(VSTR, 'T', '%54');
    VSTR := REPLACE(VSTR, 'U', '%55');
    VSTR := REPLACE(VSTR, 'V', '%56');
    VSTR := REPLACE(VSTR, 'W', '%57');
    VSTR := REPLACE(VSTR, 'X', '%58');
    VSTR := REPLACE(VSTR, 'Y', '%59');
    VSTR := REPLACE(VSTR, 'Z', '%5A');
    VSTR := REPLACE(VSTR, '[', '%5B');
    VSTR := REPLACE(VSTR, '\', '%5C');
    VSTR := REPLACE(VSTR, ']', '%5D');
    VSTR := REPLACE(VSTR, '^', '%5E');
    VSTR := REPLACE(VSTR, '_', '%5F');
    VSTR := REPLACE(VSTR, '`', '%60');
    VSTR := REPLACE(VSTR, 'a', '%61');
    VSTR := REPLACE(VSTR, 'b', '%62');
    VSTR := REPLACE(VSTR, 'c', '%63');
    VSTR := REPLACE(VSTR, 'd', '%64');
    VSTR := REPLACE(VSTR, 'e', '%65');
    VSTR := REPLACE(VSTR, 'f', '%66');
    VSTR := REPLACE(VSTR, 'g', '%67');
    VSTR := REPLACE(VSTR, 'h', '%68');
    VSTR := REPLACE(VSTR, 'i', '%69');
    VSTR := REPLACE(VSTR, 'j', '%6A');
    VSTR := REPLACE(VSTR, 'k', '%6B');
    VSTR := REPLACE(VSTR, 'l', '%6C');
    VSTR := REPLACE(VSTR, 'm', '%6D');
    VSTR := REPLACE(VSTR, 'n', '%6E');
    VSTR := REPLACE(VSTR, 'o', '%6F');
    VSTR := REPLACE(VSTR, 'p', '%70');
    VSTR := REPLACE(VSTR, 'q', '%71');
    VSTR := REPLACE(VSTR, 'r', '%72');
    VSTR := REPLACE(VSTR, 's', '%73');
    VSTR := REPLACE(VSTR, 't', '%74');
    VSTR := REPLACE(VSTR, 'u', '%75');
    VSTR := REPLACE(VSTR, 'v', '%76');
    VSTR := REPLACE(VSTR, 'w', '%77');
    VSTR := REPLACE(VSTR, 'x', '%78');
    VSTR := REPLACE(VSTR, 'y', '%79');
    VSTR := REPLACE(VSTR, 'z', '%7A');
    VSTR := REPLACE(VSTR, '{', '%7B');
    VSTR := REPLACE(VSTR, '|', '%7C');
    VSTR := REPLACE(VSTR, '}', '%7D');
    VSTR := REPLACE(VSTR, '~', '%7E');
    RETURN VSTR;
  END;

  FUNCTION GETSECRET(PUSER IN VARCHAR2, PPASS IN VARCHAR2) RETURN VARCHAR2 IS
    VKEY RAW(24); -- FACKEYS.KEY%TYPE does not work for INVISIBLE cols
  BEGIN
    SELECT KEY INTO VKEY FROM FACKEYS WHERE USERNAME = PUSER;
    RETURN DECKEY(VKEY, PPASS);
  END GETSECRET;

  FUNCTION GETGAP(PUSER IN VARCHAR2) RETURN NUMBER IS
    VGAP FACKEYS.TIME_GAP%TYPE;
  BEGIN
    SELECT TIME_GAP INTO VGAP FROM FACKEYS WHERE USERNAME = PUSER;
    RETURN VGAP;
  END GETGAP;

  FUNCTION GETMEMORY(PUSER IN VARCHAR2) RETURN NUMBER IS
    VMEM FACKEYS.MAX_TRUSTED_SOURCES%TYPE;
  BEGIN
    SELECT MAX_TRUSTED_SOURCES INTO VMEM FROM FACKEYS WHERE USERNAME = PUSER;
    RETURN VMEM;
  END GETMEMORY;

  FUNCTION CANTRYNOW(PUSER IN VARCHAR2) RETURN BOOLEAN IS
    VBFORCEPROT BFORCEPROT%ROWTYPE;
  BEGIN
    BEGIN
      SELECT * INTO VBFORCEPROT FROM BFORCEPROT WHERE USERNAME = PUSER FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RETURN TRUE;
    END;
    IF VBFORCEPROT.FIRST_FAILED IS NULL
       AND VBFORCEPROT.TRIES IS NULL
    THEN
      RETURN TRUE;
    ELSIF SYSTIMESTAMP > VBFORCEPROT.FIRST_FAILED + NUMTODSINTERVAL(VBFORCEPROT.WAIT_DURATION, 'SECOND')
          OR VBFORCEPROT.TRIES < VBFORCEPROT.MAX_TRIES
    THEN
      RETURN TRUE;
    ELSE
      RETURN FALSE;
    END IF;
  END CANTRYNOW;

  FUNCTION SECRETGEN RETURN VARCHAR2 IS
    VSECRET VARCHAR2(16 CHAR) := '';
  BEGIN
    $IF DBMS_DB_VERSION.VER_LE_10 $THEN
    SELECT REPLACE(WM_CONCAT(SUBSTR(CBASE32, TRUNC(DBMS_RANDOM.VALUE(1, 33)), 1)), ',', '')
    $ELSIF DBMS_DB_VERSION.VER_LE_11_1 $THEN
    SELECT REPLACE(WM_CONCAT(SUBSTR(CBASE32, TRUNC(DBMS_RANDOM.VALUE(1, 33)), 1)), ',', '')
    $ELSE
    SELECT LISTAGG(SUBSTR(CBASE32, TRUNC(DBMS_RANDOM.VALUE(1, 33)), 1)) WITHIN GROUP(ORDER BY ROWNUM)
    $END
    INTO   VSECRET
    FROM   DUAL
    CONNECT BY LEVEL <= 16;

    RETURN VSECRET;
  END SECRETGEN;

  FUNCTION CODEGEN(PSECRET IN VARCHAR2, PGAP IN NUMBER) RETURN CODES
    PIPELINED IS

    VBITS        VARCHAR2(80 CHAR) := ''; --16 char * 5 bits / Bits representing secret position on CBASE32
    VHEXABITS    VARCHAR2(500) := ''; -- VBITS in HEXA representation
    VUTIME       NUMBER(38); -- Unix time / POSIX Time / Epoch time
    VUTIME30CHK  VARCHAR2(16); -- Unix time in 30 secs chunks (Hexa)
    VLUTIME30CHK VARCHAR2(16); -- Unix time in 30 secs chunks (Hexa) - Last Value used
    VUTIMERANGE  NUMBER(38); -- Unix time adjusted with Gap secs
    VMAC         RAW(100);
    VOFFSET      NUMBER;
    VP1          NUMBER;
    VP2          NUMBER := POWER(2, 31) - 1;
    VOUTKEY      CODEROW; -- Store the output

    FUNCTION NUM_TO_BIN(PNUM NUMBER) RETURN VARCHAR2 IS
      VBIN VARCHAR2(8);
      VNUM NUMBER := PNUM;
    BEGIN
      IF VNUM = 0
      THEN
        RETURN '0';
      END IF;
      WHILE VNUM > 0
      LOOP
        VBIN := MOD(VNUM, 2) || VBIN;
        VNUM := FLOOR(VNUM / 2);
      END LOOP;
      RETURN VBIN;
    END NUM_TO_BIN;

    FUNCTION BIN_TO_HEX(PNUM VARCHAR2) RETURN VARCHAR2 IS
      VHEX  VARCHAR2(20);
      VHEXC VARCHAR2(1);
    BEGIN
      IF PNUM = 0
      THEN
        RETURN '0';
      END IF;
      FOR I IN 1 .. LENGTH(PNUM) / 4
      LOOP
        SELECT LTRIM(TO_CHAR(BIN_TO_NUM(TO_NUMBER(SUBSTR(PNUM, ((I - 1) * 4) + 1, 1)), TO_NUMBER(SUBSTR(PNUM, ((I - 1) * 4) + 2, 1)), TO_NUMBER(SUBSTR(PNUM, ((I - 1) * 4) + 3, 1)), TO_NUMBER(SUBSTR(PNUM, ((I - 1) * 4) + 4, 1))), 'x')) INTO VHEXC FROM DUAL;
        VHEX := VHEX || VHEXC;
      END LOOP;
      RETURN VHEX;
    END BIN_TO_HEX;

  BEGIN

    FOR C IN 1 .. LENGTH(PSECRET)
    LOOP
      VBITS := VBITS || LPAD(NUM_TO_BIN(INSTR(CBASE32, SUBSTR(PSECRET, C, 1)) - 1), 5, '0');
    END LOOP;

    VHEXABITS := BIN_TO_HEX(VBITS);

    SELECT EXTRACT(DAY FROM(DIFF)) * 86400 + EXTRACT(HOUR FROM(DIFF)) * 3600 + EXTRACT(MINUTE FROM(DIFF)) * 60 + EXTRACT(SECOND FROM(DIFF)) N INTO VUTIME FROM (SELECT CURRENT_TIMESTAMP - TIMESTAMP '1970-01-01 00:00:00 +00:00' DIFF FROM DUAL);

    VUTIMERANGE := VUTIME - FLOOR(PGAP);

    WHILE TRUE
    LOOP
      SELECT LPAD(LTRIM(TO_CHAR(FLOOR(VUTIMERANGE / 30), 'xxxxxxxxxxxxxxxx')), 16, '0') INTO VUTIME30CHK FROM DUAL;
      IF VLUTIME30CHK = VUTIME30CHK -- If last run and code don't change
      THEN
        EXIT;
      END IF;
      VMAC         := DBMS_CRYPTO.MAC(SRC => HEXTORAW(VUTIME30CHK), TYP => DBMS_CRYPTO.HMAC_SH1, KEY => HEXTORAW(VHEXABITS));
      VOFFSET      := TO_NUMBER(SUBSTR(RAWTOHEX(VMAC), -1, 1), 'x');
      VP1          := TO_NUMBER(SUBSTR(RAWTOHEX(VMAC), VOFFSET * 2 + 1, 8), 'xxxxxxxx');
      VOUTKEY.CODE := SUBSTR(BITAND(VP1, VP2), -6, 6);
      PIPE ROW(VOUTKEY);
      VLUTIME30CHK := VUTIME30CHK;
      VUTIMERANGE  := LEAST(VUTIMERANGE + 30, VUTIME + FLOOR(PGAP));
    END LOOP;
    RETURN;
  END CODEGEN;

  FUNCTION GET_GLOBAL_NAME RETURN VARCHAR2 IS
    VGNAME GLOBAL_NAME.GLOBAL_NAME%TYPE;
  BEGIN
    SELECT GLOBAL_NAME INTO VGNAME FROM GLOBAL_NAME;
    RETURN VGNAME;
  END GET_GLOBAL_NAME;

  FUNCTION URLGEN(PUSER IN VARCHAR2, PPASS IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    VPASS VARCHAR2(30 CHAR) := NVL(PPASS, DEFAULT_SECRET_PASS);
    VURLBASE  CONSTANT VARCHAR2(61 CHAR) := 'https://www.google.com/chart?chs=200x200&chld=M|0&cht=qr&chl=';
    VURLOPATH CONSTANT VARCHAR2(62 CHAR) := 'otpauth://totp/#USER#@#SERVER#?secret=#SECRET#&issuer=#ISSUER#';
    VURL  VARCHAR2(2000 CHAR);
    VUSER VARCHAR2(30 CHAR) := REPLACE(PUSER, '#', '+');
    $IF DBMS_DB_VERSION.VER_LE_10 $THEN
    VSERVER VARCHAR2(200 CHAR) := UPPER(SYS_CONTEXT('USERENV', 'DB_NAME'));
    $ELSIF DBMS_DB_VERSION.VER_LE_11 $THEN
    VSERVER VARCHAR2(200 CHAR) := UPPER(SYS_CONTEXT('USERENV', 'DB_NAME'));
    $ELSE
    VSERVER VARCHAR2(200 CHAR) := UPPER(SYS_CONTEXT('USERENV', 'CON_NAME'));
    $END
    VISSUER VARCHAR2(200 CHAR) := 'DB Server - ' || LOWER(GET_GLOBAL_NAME);
  BEGIN
    VURL := VURLOPATH;
    VURL := REPLACE(VURL, '#USER#', VUSER);
    VURL := REPLACE(VURL, '#SERVER#', VSERVER);
    VURL := REPLACE(VURL, '#SECRET#', GETSECRET(PUSER, VPASS));
    VURL := REPLACE(VURL, '#ISSUER#', VISSUER);
    VURL := VURLBASE || CONVURLENCODE(VURL);
    --VURL := VURLBASE || VURL;
    RETURN VURL;
  END URLGEN;

  PROCEDURE SETSTATUS(PUSER IN VARCHAR2, PSTATUS IN VARCHAR2) IS
  BEGIN
    UPDATE FACKEYS SET STATUS = PSTATUS WHERE USERNAME = PUSER;
    COMMIT;
  END SETSTATUS;

  PROCEDURE SETVALIDATED(PUSER IN VARCHAR2) IS
  BEGIN
    UPDATE FACKEYS SET VALIDATED = 'VALIDATED' WHERE USERNAME = PUSER;
    COMMIT;
  END SETVALIDATED;

  PROCEDURE SETAUTHENTICATED IS
  BEGIN
    DBMS_SESSION.SET_CONTEXT('TWOFACTOR_CTX', 'AUTHENTICATED', 'TRUE');
  END SETAUTHENTICATED;

  PROCEDURE INCLASTTRY(PUSER IN VARCHAR2, PCLEAN IN BOOLEAN DEFAULT FALSE) IS
    VBFORCEPROT BFORCEPROT%ROWTYPE;
  BEGIN
    BEGIN
      SELECT * INTO VBFORCEPROT FROM BFORCEPROT WHERE USERNAME = PUSER;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RETURN;
    END;
    IF PCLEAN -- If code is right, clean data
    THEN
      IF VBFORCEPROT.FIRST_FAILED IS NOT NULL
      THEN
        UPDATE BFORCEPROT
        SET    FIRST_FAILED = NULL,
               TRIES        = NULL
        WHERE  USERNAME = PUSER;
      END IF;
    ELSIF VBFORCEPROT.FIRST_FAILED IS NULL -- If code is wrong and this is the first wrong attempt
    THEN
      UPDATE BFORCEPROT
      SET    FIRST_FAILED = SYSTIMESTAMP,
             TRIES        = 1
      WHERE  USERNAME = PUSER;
    ELSIF SYSTIMESTAMP > VBFORCEPROT.FIRST_FAILED + NUMTODSINTERVAL(VBFORCEPROT.WAIT_DURATION, 'SECOND') -- If code is wrong and this is already too far from the first wrong attempt
    THEN
      UPDATE BFORCEPROT
      SET    FIRST_FAILED = SYSTIMESTAMP,
             TRIES        = 1
      WHERE  USERNAME = PUSER;
    ELSE
      -- If code is wrong and we are still inside tries window
      UPDATE BFORCEPROT SET TRIES = LEAST(TRIES + 1, MAX_TRIES) WHERE USERNAME = PUSER;
    END IF;
    COMMIT;
  END INCLASTTRY;

  FUNCTION CODECHECK(PUSER IN VARCHAR2, PCODE IN VARCHAR2, PPASS IN VARCHAR2 DEFAULT NULL) RETURN BOOLEAN IS
    VPASS   VARCHAR2(30 CHAR) := NVL(PPASS, DEFAULT_SECRET_PASS);
    VFIND   NUMBER;
    VSECRET VARCHAR2(16 CHAR);
    VGAP    FACKEYS.TIME_GAP%TYPE;
  BEGIN
    -- To avoid BForce, check if user can try
    IF NOT (CANTRYNOW(PUSER)) -- CANTRYNOW lock the user row to avoid parallel execution of this function = Parallel BForce Attack
    THEN
      ROLLBACK; -- Release Lock of "FOR UPDATE" inside CANTRYNOW
      RETURN FALSE;
    END IF;
    VGAP := GETGAP(PUSER);
    BEGIN
      VSECRET := GETSECRET(PUSER, VPASS);
      -- Wrong Password throughs exception on GETSECRET -> DECKEY
    EXCEPTION
      WHEN OTHERS THEN
        INCLASTTRY(PUSER);
        RETURN FALSE;
    END;
    SELECT COUNT(*) INTO VFIND FROM TABLE(CODEGEN(VSECRET, VGAP)) WHERE CODE = PCODE;
    IF VFIND = 0
    THEN
      INCLASTTRY(PUSER);
      RETURN FALSE;
    ELSE
      INCLASTTRY(PUSER, TRUE);
      RETURN TRUE;
    END IF;
  END CODECHECK;

  PROCEDURE ADDUSER(PUSER IN VARCHAR2, PGAP IN NUMBER DEFAULT NULL, PPASS IN VARCHAR2 DEFAULT NULL) IS
    VPASS VARCHAR2(30 CHAR) := NVL(PPASS, DEFAULT_SECRET_PASS);
    VKEY  RAW(24) := ENCKEY(SECRETGEN, VPASS); -- FACKEYS.KEY%TYPE does not work for INVISIBLE cols
  BEGIN
    IF PGAP IS NULL -- This could be avoided on 12c+ with new "DEFAULT ON NULL" clause, but not on prior versions
    THEN
      INSERT INTO FACKEYS
        (USERNAME,
         KEY)
      VALUES
        (PUSER,
         VKEY);
    ELSE
      INSERT INTO FACKEYS
        (USERNAME,
         KEY,
         TIME_GAP)
      VALUES
        (PUSER,
         VKEY,
         PGAP);
    END IF;
    INSERT INTO BFORCEPROT (USERNAME) VALUES (PUSER);
    COMMIT;
  END ADDUSER;

  PROCEDURE REMUSER(PUSER IN VARCHAR2) IS
  BEGIN
    DELETE FROM FACKEYS WHERE USERNAME = PUSER;
    COMMIT;
  END REMUSER;

  FUNCTION HASMEMORY(PUSER IN VARCHAR2) RETURN BOOLEAN IS
    VFIND NUMBER;
  BEGIN
    SELECT COUNT(*)
    INTO   VFIND
    FROM   TRUSTEDLOCS
    WHERE  USERNAME = PUSER
    AND    SYSTIMESTAMP BETWEEN START_DATE AND END_DATE;
    IF VFIND >= GETMEMORY(PUSER)
    THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
  END HASMEMORY;

  PROCEDURE REMMEMORY IS
  BEGIN
    DELETE TRUSTEDLOCS B
    WHERE  EXISTS (SELECT 1
            FROM   V$SESSION A
            WHERE  A.AUDSID = SYS_CONTEXT('USERENV', 'SESSIONID')
            AND    A.SID = SYS_CONTEXT('USERENV', 'SID')
            AND    A.USERNAME = B.USERNAME
            AND    A.OSUSER = B.OSUSER
            AND    A.MACHINE = B.MACHINE
            AND    A.TERMINAL = B.TERMINAL
            AND    A.PROGRAM = B.PROGRAM
            AND    B.IP_ADDRESS = SYS_CONTEXT('USERENV', 'IP_ADDRESS')
            AND    SYSTIMESTAMP BETWEEN B.START_DATE AND B.END_DATE);
    -- Do not COMMIT; --ADDMEMORY will commit
  END REMMEMORY;

  FUNCTION ADDMEMORY(PUSER IN VARCHAR2, PINT INTERVAL DAY TO SECOND DEFAULT INTERVAL '7' DAY) RETURN BOOLEAN IS
    VREM TRUSTEDLOCS%ROWTYPE;
    VINT INTERVAL DAY TO SECOND := NVL(PINT, INTERVAL '7' DAY);
    CURSOR C1 IS
      SELECT MAX_TRUSTED_SOURCES FROM FACKEYS WHERE USERNAME = PUSER FOR UPDATE; -- Just to get a user lock, nothing will be changed
  BEGIN
    -- Locks here are to avoid parallel memory attack
    OPEN C1; -- Get lock for user
    IF HASMEMORY(PUSER)
    THEN
      -- Module and Action removed as they are defined after login trigger from DBMS_APPLICATION_INFO.
      SELECT USERNAME,
             OSUSER,
             MACHINE,
             TERMINAL,
             PROGRAM,
             SYS_CONTEXT('USERENV', 'IP_ADDRESS') IP_ADDRESS
      INTO   VREM.USERNAME,
             VREM.OSUSER,
             VREM.MACHINE,
             VREM.TERMINAL,
             VREM.PROGRAM,
             VREM.IP_ADDRESS
      FROM   V$SESSION
      WHERE  AUDSID = SYS_CONTEXT('USERENV', 'SESSIONID')
      AND    SID = SYS_CONTEXT('USERENV', 'SID');
      VREM.START_DATE := SYSTIMESTAMP;
      VREM.END_DATE   := VREM.START_DATE + VINT;
      INSERT INTO TRUSTEDLOCS VALUES VREM;
      COMMIT; -- Release lock
      CLOSE C1;
      RETURN TRUE;
    ELSE
      -- Memory is Full
      ROLLBACK; -- Release lock
      CLOSE C1;
      RETURN FALSE;
    END IF;
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      REMMEMORY;
      RETURN ADDMEMORY(PUSER, VINT);
  END ADDMEMORY;

  PROCEDURE CLEANMEMORY(PUSER IN VARCHAR2) IS
  BEGIN
    DELETE TRUSTEDLOCS WHERE USERNAME = PUSER;
    COMMIT;
  END CLEANMEMORY;

  FUNCTION ISUSERSETUP(PUSER IN VARCHAR2) RETURN BOOLEAN IS
    VFIND NUMBER;
  BEGIN
    SELECT COUNT(*) INTO VFIND FROM FACKEYS WHERE USERNAME = PUSER;
    IF VFIND = 0
    THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
  END ISUSERSETUP;

  FUNCTION ISUSERENABLED(PUSER IN VARCHAR2) RETURN BOOLEAN IS
    VFIND NUMBER;
  BEGIN
    SELECT COUNT(*)
    INTO   VFIND
    FROM   FACKEYS
    WHERE  USERNAME = PUSER
    AND    STATUS = 'ENABLED';
    IF VFIND = 0
    THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
  END ISUSERENABLED;

  FUNCTION ISUSERVALIDATED(PUSER IN VARCHAR2) RETURN BOOLEAN IS
    VFIND NUMBER;
  BEGIN
    SELECT COUNT(*)
    INTO   VFIND
    FROM   FACKEYS
    WHERE  USERNAME = PUSER
    AND    VALIDATED = 'VALIDATED';
    IF VFIND = 0
    THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
  END ISUSERVALIDATED;

  FUNCTION ISUSERREMEMBERED RETURN BOOLEAN IS
    VFIND NUMBER;
  BEGIN
    SELECT COUNT(*)
    INTO   VFIND
    FROM   V$SESSION A,
           TRUSTEDLOCS B
    WHERE  A.AUDSID = SYS_CONTEXT('USERENV', 'SESSIONID')
    AND    A.SID = SYS_CONTEXT('USERENV', 'SID')
    AND    A.USERNAME = B.USERNAME
    AND    A.OSUSER = B.OSUSER
    AND    A.MACHINE = B.MACHINE
    AND    NVL(A.TERMINAL, ' ') = NVL(B.TERMINAL, ' ')
    AND    A.PROGRAM = B.PROGRAM
    AND    NVL(B.IP_ADDRESS, ' ') = NVL(SYS_CONTEXT('USERENV', 'IP_ADDRESS'), ' ')
    AND    SYSTIMESTAMP BETWEEN B.START_DATE AND B.END_DATE;
    IF VFIND = 0
    THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
  END ISUSERREMEMBERED;

  PROCEDURE CHECKANDAUTHUSER AS
    VUSER CONSTANT VARCHAR2(30 CHAR) := SYS_CONTEXT('USERENV', 'SESSION_USER');
  BEGIN
    IF NOT ISUSERSETUP(VUSER) -- Not Setup
    THEN
      DBMS_SESSION.SET_CONTEXT('TWOFACTOR_CTX', 'AUTHENTICATED', 'NOT SETUP');
    ELSIF NOT ISUSERVALIDATED(VUSER) -- Not Validated
    THEN
      DBMS_SESSION.SET_CONTEXT('TWOFACTOR_CTX', 'AUTHENTICATED', 'NOT VALIDATED');
    ELSIF NOT ISUSERENABLED(VUSER) -- Not Enabled
    THEN
      DBMS_SESSION.SET_CONTEXT('TWOFACTOR_CTX', 'AUTHENTICATED', 'NOT ENABLED');
    ELSIF ISUSERREMEMBERED() -- Is Remembered!
    THEN
      SETAUTHENTICATED;
    ELSE
      DBMS_SESSION.SET_CONTEXT('TWOFACTOR_CTX', 'AUTHENTICATED', 'FALSE');
    END IF;

  END CHECKANDAUTHUSER;

END TWOFACTOR_INTERNAL;
/
