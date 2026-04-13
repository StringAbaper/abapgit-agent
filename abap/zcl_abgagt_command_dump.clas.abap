*"*"use source
*"*"Local Interface:
**********************************************************************
" DUMP command implementation - query short dumps from ST22
" ECC 7.40 compatible: reads SNAP table + FLIST parsing (no SNAP_ADT dependency)
CLASS zcl_abgagt_command_dump DEFINITION
  PUBLIC FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_abgagt_command.

    TYPES:
      BEGIN OF ty_dump_params,
        user      TYPE syuname,
        date_from TYPE sydatum,
        date_to   TYPE sydatum,
        time_from TYPE syuzeit,
        time_to   TYPE syuzeit,
        ts_from   TYPE string,    " UTC timestamp filter: YYYYMMDDhhmmss
        ts_to     TYPE string,    " UTC timestamp filter: YYYYMMDDhhmmss
        program   TYPE syrepid,
        error     TYPE s380errid,
        limit     TYPE i,
        detail    TYPE string,
      END OF ty_dump_params.

    TYPES:
      BEGIN OF ty_stack_entry,
        level     TYPE i,
        class     TYPE string,
        method    TYPE string,
        program   TYPE string,
        include   TYPE string,
        line      TYPE i,
      END OF ty_stack_entry.

    TYPES ty_stack_entries TYPE STANDARD TABLE OF ty_stack_entry WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_dump_item,
        id             TYPE string,
        utc_timestamp  TYPE string,    " UTC timestamp: YYYYMMDDhhmmss
        date           TYPE string,    " Server local date (YYYY-MM-DD)
        time           TYPE string,    " Server local time (HH:MM:SS)
        user           TYPE syuname,
        program        TYPE syrepid,
        object         TYPE sobj_name,
        error          TYPE string,
        exception      TYPE string,
        package        TYPE devclass,
        host           TYPE snap_syinst,
        what_happened  TYPE string,
        error_analysis TYPE string,
        source_line    TYPE i,
        source_include TYPE syrepid,
        call_stack     TYPE ty_stack_entries,
      END OF ty_dump_item.

    TYPES ty_dump_items TYPE STANDARD TABLE OF ty_dump_item WITH DEFAULT KEY.

    TYPES:
      BEGIN OF ty_dump_result,
        success TYPE abap_bool,
        command TYPE string,
        message TYPE string,
        total   TYPE i,
        dumps   TYPE ty_dump_items,
        error   TYPE string,
      END OF ty_dump_result.

  PRIVATE SECTION.
    " Build a composite ID from SNAP key fields using : as separator
    METHODS build_id
      IMPORTING
        iv_datum TYPE sydatum
        iv_uzeit TYPE syuzeit
        iv_ahost TYPE snap_syinst
        iv_uname TYPE syuname
        iv_mandt TYPE mandt
        iv_modno TYPE sywpid
      RETURNING
        VALUE(rv_id) TYPE string.

    " Parse a composite ID back into a SNAP_KEY structure
    METHODS parse_id
      IMPORTING
        iv_id TYPE string
      RETURNING
        VALUE(rs_key) TYPE snap_key.

    " Metadata extracted from the SNAP FLIST stream
    TYPES:
      BEGIN OF ty_flist_info,
        errid     TYPE s380errid,  " FC - runtime error name
        mainprog  TYPE syrepid,    " AM - main program
        program   TYPE syrepid,    " AP - application program (current)
        include   TYPE syrepid,    " AI - application include
        lineno    TYPE string,     " AL - application line number
        exception TYPE string,     " XC - exception class name
      END OF ty_flist_info.

    " Parse SNAP FLIST stream to extract dump metadata
    " Same technique as FM RS_ST22_GET_DUMPS: reads SEQNO='000' FLIST fields
    " Format: stream of [2-char attr code][3-digit length][data] terminated by '%'
    METHODS parse_flist
      IMPORTING
        is_snap        TYPE snap
      RETURNING
        VALUE(rs_info) TYPE ty_flist_info.

    " Convert server-local datum/uzeit to UTC timestamp string (YYYYMMDDhhmmss)
    METHODS get_utc_timestamp
      IMPORTING
        iv_datum            TYPE sydatum
        iv_uzeit            TYPE syuzeit
        iv_sys_tz           TYPE timezone
      RETURNING
        VALUE(rv_timestamp) TYPE string.
ENDCLASS.

CLASS zcl_abgagt_command_dump IMPLEMENTATION.

  METHOD zif_abgagt_command~get_name.
    rv_name = zif_abgagt_command=>gc_dump.
  ENDMETHOD.

  METHOD zif_abgagt_command~execute.
    DATA ls_params   TYPE ty_dump_params.
    DATA ls_result   TYPE ty_dump_result.

    ls_result-command = zif_abgagt_command=>gc_dump.

    IF is_param IS SUPPLIED.
      ls_params = CORRESPONDING #( is_param ).
    ENDIF.

    " Enforce limit: default 20, max 100
    IF ls_params-limit <= 0 OR ls_params-limit > 100.
      ls_params-limit = 20.
    ENDIF.
    DATA(lv_limit) = ls_params-limit.

    " Cache system timezone for UTC conversions
    DATA lv_sys_tz TYPE timezone.
    CALL FUNCTION 'GET_SYSTEM_TIMEZONE'
      IMPORTING timezone = lv_sys_tz.

    " ── Detail mode: load full dump text for a specific dump ID ────
    IF ls_params-detail IS NOT INITIAL.
      DATA(ls_key) = parse_id( ls_params-detail ).

      DATA lt_keys TYPE snap_keys.
      APPEND ls_key TO lt_keys.

      TRY.
          cl_runtime_error=>create(
            EXPORTING p_i_t_snapkeys    = lt_keys
            IMPORTING p_e_t_snapentries = DATA(lt_entries) ).

          IF lt_entries IS INITIAL.
            ls_result-success = abap_false.
            ls_result-error = 'Short dump not found'.
            rv_result = /ui2/cl_json=>serialize( data = ls_result ).
            RETURN.
          ENDIF.

          " SNAP_ENTRIES is a table of CL_RUNTIME_ERROR object references
          DATA(lo_dump) = lt_entries[ 1 ].
          DATA ls_item TYPE ty_dump_item.
          ls_item-id = ls_params-detail.

          lo_dump->get_what_happened_text(
            CHANGING p_text = ls_item-what_happened ).
          lo_dump->get_error_analysis_text(
            IMPORTING p_text = ls_item-error_analysis ).

          " Get structured call stack (frame list with line numbers)
          DATA lt_stack TYPE snap_abap_stack.
          lo_dump->get_abap_callstack(
            IMPORTING p_abap_stack = lt_stack ).
          LOOP AT lt_stack INTO DATA(ls_frame).
            DATA ls_entry TYPE ty_stack_entry.
            ls_entry-level   = ls_frame-index.
            ls_entry-class   = ls_frame-classname.
            ls_entry-method  = ls_frame-event.
            ls_entry-program = ls_frame-program.
            ls_entry-include = ls_frame-include.
            ls_entry-line    = ls_frame-linenr.
            APPEND ls_entry TO ls_item-call_stack.
          ENDLOOP.

          " Get source code at error location with >>>>> marker on error line
          DATA lt_source TYPE sourcetable.
          DATA lv_error_lineno TYPE i.
          DATA lv_error_include TYPE syrepid.
          DATA lv_mainprog TYPE syrepid.
          lo_dump->get_abap_sourceinfo(
            IMPORTING
              p_e_include     = lv_error_include
              p_e_mainprogram = lv_mainprog
              p_e_lineno      = lv_error_lineno
              p_e_sourcetext  = lt_source ).

          IF lt_source IS NOT INITIAL AND lv_error_lineno > 0.
            ls_item-source_line    = lv_error_lineno.
            ls_item-source_include = lv_error_include.
            DATA lv_source_with_marker TYPE string.
            LOOP AT lt_source INTO DATA(lv_src_line).
              DATA(lv_idx) = sy-tabix.
              IF lv_idx = lv_error_lineno.
                lv_source_with_marker = lv_source_with_marker
                  && |>>>>> { lv_src_line }|
                  && cl_abap_char_utilities=>newline.
              ELSE.
                lv_source_with_marker = lv_source_with_marker
                  && |      { lv_src_line }|
                  && cl_abap_char_utilities=>newline.
              ENDIF.
            ENDLOOP.
            DATA ls_src_entry TYPE ty_stack_entry.
            ls_src_entry-method = lv_source_with_marker.
            APPEND ls_src_entry TO ls_item-call_stack.
          ELSEIF ls_item-call_stack IS INITIAL.
            " No source info available: fall back to section text
            DATA lv_stack_heading TYPE string.
            DATA lv_stack_text    TYPE string.
            lo_dump->get_section_text(
              EXPORTING section_id      = cl_runtime_error=>c_section_abap_eventstack
              IMPORTING section_heading = lv_stack_heading
                        section_text    = lv_stack_text ).
            IF lv_stack_text IS INITIAL.
              lo_dump->get_section_text(
                EXPORTING section_id      = cl_runtime_error=>c_section_abap_source
                IMPORTING section_heading = lv_stack_heading
                          section_text    = lv_stack_text ).
            ENDIF.
            IF lv_stack_text IS NOT INITIAL.
              DATA ls_text_entry TYPE ty_stack_entry.
              ls_text_entry-method = lv_stack_text.
              APPEND ls_text_entry TO ls_item-call_stack.
            ENDIF.
          ENDIF.

          " Populate metadata from CL_RUNTIME_ERROR instance + snap_key
          ls_item-date          = |{ ls_key-datum+0(4) }-{ ls_key-datum+4(2) }-{ ls_key-datum+6(2) }|.
          ls_item-time          = |{ ls_key-uzeit+0(2) }:{ ls_key-uzeit+2(2) }:{ ls_key-uzeit+4(2) }|.
          ls_item-utc_timestamp = get_utc_timestamp(
                                    iv_datum  = ls_key-datum
                                    iv_uzeit  = ls_key-uzeit
                                    iv_sys_tz = lv_sys_tz ).
          ls_item-user          = ls_key-uname.
          ls_item-host          = ls_key-ahost.
          ls_item-program       = lv_mainprog.
          ls_item-error         = lo_dump->get_errid( ).
          lo_dump->get_exception(
            IMPORTING p_exception = ls_item-exception ).

          APPEND ls_item TO ls_result-dumps.
          ls_result-success = abap_true.
          ls_result-total   = 1.
          ls_result-message = 'Short dump detail retrieved'.

        CATCH cx_runtime_error_exc_auth.
          ls_result-success = abap_false.
          ls_result-error   = 'Not authorized to read short dumps'.
        CATCH cx_root INTO DATA(lx_error).
          ls_result-success = abap_false.
          ls_result-error   = lx_error->get_text( ).
      ENDTRY.

      rv_result = /ui2/cl_json=>serialize( data = ls_result ).
      RETURN.
    ENDIF.

    " ── List mode: read from SNAP table (always populated on 7.40+) ──
    " Reads SEQNO='000' header records and parses FLIST stream for metadata,
    " same technique as FM RS_ST22_GET_DUMPS.
    DATA lt_snap TYPE STANDARD TABLE OF snap WITH DEFAULT KEY.

    " Note: @variable IS INITIAL is NOT supported in SQL WHERE on 7.40,
    " so we use IF/ELSE branches for the optional user filter.
    " Time/error/program filtering is done in ABAP after FLIST parsing.
    DATA(lv_f_user) = ls_params-user.

    IF ls_params-ts_from IS NOT INITIAL.
      " UTC timestamp mode: convert to server-local date range, post-filter for precision
      DATA lv_ts_from TYPE timestamp.
      DATA lv_ts_to   TYPE timestamp.
      lv_ts_from = ls_params-ts_from.
      lv_ts_to   = ls_params-ts_to.

      DATA lv_date_from TYPE d.
      DATA lv_date_to   TYPE d.
      DATA lv_time_tmp  TYPE t.
      CONVERT TIME STAMP lv_ts_from TIME ZONE lv_sys_tz
        INTO DATE lv_date_from TIME lv_time_tmp.
      CONVERT TIME STAMP lv_ts_to TIME ZONE lv_sys_tz
        INTO DATE lv_date_to TIME lv_time_tmp.

      IF lv_f_user IS NOT INITIAL.
        SELECT * FROM snap INTO TABLE @lt_snap
          WHERE mandt = @sy-mandt
            AND datum BETWEEN @lv_date_from AND @lv_date_to
            AND seqno = '000'
            AND uname = @lv_f_user.
      ELSE.
        SELECT * FROM snap INTO TABLE @lt_snap
          WHERE mandt = @sy-mandt
            AND datum BETWEEN @lv_date_from AND @lv_date_to
            AND seqno = '000'.
      ENDIF.
    ELSE.
      " Server-local time mode (default: last 7 days)
      IF ls_params-date_from IS INITIAL.
        ls_params-date_from = sy-datum - 7.
      ENDIF.
      IF ls_params-date_to IS INITIAL.
        ls_params-date_to = sy-datum.
      ENDIF.

      IF lv_f_user IS NOT INITIAL.
        SELECT * FROM snap INTO TABLE @lt_snap
          WHERE mandt = @sy-mandt
            AND datum BETWEEN @ls_params-date_from AND @ls_params-date_to
            AND seqno = '000'
            AND uname = @lv_f_user.
      ELSE.
        SELECT * FROM snap INTO TABLE @lt_snap
          WHERE mandt = @sy-mandt
            AND datum BETWEEN @ls_params-date_from AND @ls_params-date_to
            AND seqno = '000'.
      ENDIF.
    ENDIF.

    " Sort newest first
    SORT lt_snap BY datum DESCENDING uzeit DESCENDING.

    " Parse FLIST, apply filters, build result
    DATA lv_count TYPE i.
    LOOP AT lt_snap INTO DATA(ls_snap).
      DATA(ls_flist) = parse_flist( ls_snap ).

      " Apply time filter (server-local mode only, not done in SQL for 7.40 compat)
      IF ls_params-ts_from IS INITIAL.
        IF ls_params-time_from IS NOT INITIAL AND ls_snap-uzeit < ls_params-time_from.
          CONTINUE.
        ENDIF.
        IF ls_params-time_to IS NOT INITIAL AND ls_snap-uzeit > ls_params-time_to.
          CONTINUE.
        ENDIF.
      ENDIF.

      " Apply error filter (errid is in FLIST, not a SQL column)
      IF ls_params-error IS NOT INITIAL AND ls_flist-errid <> ls_params-error.
        CONTINUE.
      ENDIF.

      " Determine program name: prefer mainprog (AM), fall back to program (AP)
      DATA(lv_prog) = COND syrepid(
        WHEN ls_flist-mainprog IS NOT INITIAL THEN ls_flist-mainprog
        ELSE ls_flist-program ).

      " Apply program filter
      IF ls_params-program IS NOT INITIAL AND lv_prog <> ls_params-program.
        CONTINUE.
      ENDIF.

      " UTC timestamp post-filter for precision in timestamp mode
      IF ls_params-ts_from IS NOT INITIAL.
        DATA lv_entry_ts TYPE timestamp.
        CONVERT DATE ls_snap-datum TIME ls_snap-uzeit
          INTO TIME STAMP lv_entry_ts TIME ZONE lv_sys_tz.
        IF lv_entry_ts < lv_ts_from OR lv_entry_ts > lv_ts_to.
          CONTINUE.
        ENDIF.
      ENDIF.

      lv_count = lv_count + 1.
      IF lv_count > lv_limit.
        EXIT.
      ENDIF.

      DATA ls_row TYPE ty_dump_item.
      ls_row-id        = build_id(
                           iv_datum = ls_snap-datum
                           iv_uzeit = ls_snap-uzeit
                           iv_ahost = ls_snap-ahost
                           iv_uname = ls_snap-uname
                           iv_mandt = ls_snap-mandt
                           iv_modno = ls_snap-modno ).
      ls_row-utc_timestamp = get_utc_timestamp(
                               iv_datum  = ls_snap-datum
                               iv_uzeit  = ls_snap-uzeit
                               iv_sys_tz = lv_sys_tz ).
      ls_row-date      = |{ ls_snap-datum+0(4) }-{ ls_snap-datum+4(2) }-{ ls_snap-datum+6(2) }|.
      ls_row-time      = |{ ls_snap-uzeit+0(2) }:{ ls_snap-uzeit+2(2) }:{ ls_snap-uzeit+4(2) }|.
      ls_row-user      = ls_snap-uname.
      ls_row-program   = lv_prog.
      ls_row-error     = ls_flist-errid.
      ls_row-exception = ls_flist-exception.
      ls_row-host      = ls_snap-ahost.
      APPEND ls_row TO ls_result-dumps.
    ENDLOOP.

    ls_result-success = abap_true.
    ls_result-total   = lines( ls_result-dumps ).
    ls_result-message = |{ ls_result-total } short dump(s) found|.
    rv_result = /ui2/cl_json=>serialize( data = ls_result ).
  ENDMETHOD.

  METHOD build_id.
    " Encode the 6-part SNAP_KEY as a colon-delimited string
    " Order matches SNAP_KEY: datum, uzeit, ahost, uname, mandt, modno
    rv_id = |{ iv_datum }:{ iv_uzeit }:{ iv_ahost }:{ iv_uname }:{ iv_mandt }:{ iv_modno }|.
  ENDMETHOD.

  METHOD parse_id.
    DATA lt_parts TYPE STANDARD TABLE OF string WITH DEFAULT KEY.
    SPLIT iv_id AT ':' INTO TABLE lt_parts.
    TRY.
        rs_key-datum  = lt_parts[ 1 ].
        rs_key-uzeit  = lt_parts[ 2 ].
        rs_key-ahost  = lt_parts[ 3 ].
        rs_key-uname  = lt_parts[ 4 ].
        rs_key-mandt  = lt_parts[ 5 ].
        rs_key-modno  = lt_parts[ 6 ].
    CATCH cx_sy_itab_line_not_found ##NO_HANDLER.
    ENDTRY.
  ENDMETHOD.

  METHOD parse_flist.
    " Parse SNAP FLIST stream — same technique as FM RS_ST22_GET_DUMPS.
    " SNAP stores dump attributes in FLIST..FLIST08 (8 x CHAR 200 = 1600 bytes).
    " Format: stream of [2-char attr code][3-digit length][data] terminated by '%'.
    FIELD-SYMBOLS <buffer> TYPE c.
    ASSIGN is_snap-flist(1600) TO <buffer> RANGE is_snap.

    DATA lv_x   TYPE i.
    DATA lv_y   TYPE i.
    DATA lv_cnt TYPE i.

    CATCH SYSTEM-EXCEPTIONS conversion_errors = 0 data_access_errors = 0.

      WHILE <buffer>+lv_x(1) <> '%' AND lv_cnt < 6.
        CASE <buffer>+lv_x(2).
          WHEN 'FC'.                    " runtime error name (e.g. MESSAGE_TYPE_X)
            ADD 1 TO lv_cnt.
            ADD 2 TO lv_x.
            lv_y = <buffer>+lv_x(3).
            ADD 3 TO lv_x.
            rs_info-errid = <buffer>+lv_x(lv_y).
            ADD lv_y TO lv_x.
          WHEN 'AM'.                    " main program
            ADD 1 TO lv_cnt.
            ADD 2 TO lv_x.
            lv_y = <buffer>+lv_x(3).
            ADD 3 TO lv_x.
            rs_info-mainprog = <buffer>+lv_x(lv_y).
            ADD lv_y TO lv_x.
          WHEN 'AP'.                    " application program (current at crash)
            ADD 1 TO lv_cnt.
            ADD 2 TO lv_x.
            lv_y = <buffer>+lv_x(3).
            ADD 3 TO lv_x.
            rs_info-program = <buffer>+lv_x(lv_y).
            ADD lv_y TO lv_x.
          WHEN 'AI'.                    " application include
            ADD 1 TO lv_cnt.
            ADD 2 TO lv_x.
            lv_y = <buffer>+lv_x(3).
            ADD 3 TO lv_x.
            rs_info-include = <buffer>+lv_x(lv_y).
            ADD lv_y TO lv_x.
          WHEN 'AL'.                    " application line number
            ADD 1 TO lv_cnt.
            ADD 2 TO lv_x.
            lv_y = <buffer>+lv_x(3).
            ADD 3 TO lv_x.
            rs_info-lineno = <buffer>+lv_x(lv_y).
            ADD lv_y TO lv_x.
          WHEN 'XC'.                    " exception class name
            ADD 1 TO lv_cnt.
            ADD 2 TO lv_x.
            lv_y = <buffer>+lv_x(3).
            ADD 3 TO lv_x.
            rs_info-exception = <buffer>+lv_x(lv_y).
            ADD lv_y TO lv_x.
          WHEN OTHERS.
            " Skip unknown attributes
            ADD 2 TO lv_x.
            lv_x = lv_x + 3 + <buffer>+lv_x(3).
        ENDCASE.
      ENDWHILE.

    ENDCATCH.
  ENDMETHOD.

  METHOD get_utc_timestamp.
    DATA lv_ts TYPE timestamp.
    CONVERT DATE iv_datum TIME iv_uzeit
      INTO TIME STAMP lv_ts TIME ZONE iv_sys_tz.
    rv_timestamp = |{ lv_ts }|.
  ENDMETHOD.

ENDCLASS.
