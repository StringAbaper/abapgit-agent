*"*"use source
*"*"Local Interface:
*"**********************************************************************
"! <p class="shorttext synchronized">Viewer pour les vues ABAP (VIEW)</p>
"! Retourne la définition d'une vue ABAP : type, tables jointes,
"! conditions de sélection, statut de gestion et champs.
CLASS zcl_abgagt_viewer_view DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_abgagt_viewer.

ENDCLASS.

CLASS zcl_abgagt_viewer_view IMPLEMENTATION.

  METHOD zif_abgagt_viewer~get_info.
    DATA: lv_devclass   TYPE tadir-devclass,
          lt_comp       TYPE STANDARD TABLE OF zcl_abgagt_command_view=>ty_component WITH DEFAULT KEY,
          ls_comp       TYPE zcl_abgagt_command_view=>ty_component,
          ls_dd03l      TYPE dd03l,
          lv_viewname   TYPE dd25l-viewname,
          lv_ddtext     TYPE dd25t-ddtext,
          lv_fieldname  TYPE dd03l-fieldname,
          lv_rollname   TYPE dd03l-rollname,
          lv_type_text  TYPE string,
          lv_viewclass  TYPE dd25l-viewclass,
          lv_globalflag TYPE dd25l-globalflag,
          lv_viewgrant  TYPE dd25l-viewgrant,
          lv_readonly   TYPE dd25l-readonly,
          lv_dbrefname  TYPE dd25l-dbrefname,
          lt_dd26s      TYPE STANDARD TABLE OF dd26s WITH DEFAULT KEY,
          ls_dd26s      TYPE dd26s,
          lt_dd28s      TYPE STANDARD TABLE OF dd28s WITH DEFAULT KEY,
          ls_dd28s      TYPE dd28s,
          lv_condname   TYPE dd28s-condname,
          lv_source     TYPE string,
          lv_maint      TYPE string,
          lv_cond_line  TYPE string.

    lv_viewname = iv_name.
    lv_condname = iv_name.

    rs_info-name = iv_name.
    rs_info-type = 'VIEW'.

    " Lecture de l'en-tête de la vue dans DD25L
    SELECT SINGLE viewclass, globalflag, viewgrant, readonly, dbrefname
      FROM dd25l
      INTO (@lv_viewclass, @lv_globalflag, @lv_viewgrant, @lv_readonly, @lv_dbrefname)
      WHERE viewname = @lv_viewname
        AND as4local = 'A'.

    IF sy-subrc <> 0.
      rs_info-type_text = 'View'.
      rs_info-not_found = abap_true.
      RETURN.
    ENDIF.

    " Type de vue
    CASE lv_viewclass.
      WHEN 'D'. lv_type_text = 'Database View'.
      WHEN 'P'. lv_type_text = 'Projection View'.
      WHEN 'H'. lv_type_text = 'Help View'.
      WHEN 'M'. lv_type_text = 'Maintenance View'.
      WHEN OTHERS. lv_type_text = 'View'.
    ENDCASE.
    rs_info-type_text = lv_type_text.

    " Texte court de la vue (langue EN, fallback sans filtre langue)
    SELECT SINGLE ddtext FROM dd25t INTO @lv_ddtext
      WHERE viewname   = @lv_viewname
        AND ddlanguage = 'E'
        AND as4local   = 'A'.
    IF sy-subrc <> 0.
      SELECT SINGLE ddtext FROM dd25t INTO @lv_ddtext
        WHERE viewname = @lv_viewname
          AND as4local = 'A'.
    ENDIF.

    " Paquet depuis TADIR
    SELECT SINGLE devclass FROM tadir INTO @lv_devclass
      WHERE obj_name = @iv_name
        AND object   = 'VIEW'.

    " Statut de gestion
    IF lv_readonly = 'X'.
      lv_maint = 'Display only'.
    ELSEIF lv_globalflag = 'X'.
      lv_maint = 'Display and Maintenance'.
    ELSE.
      lv_maint = 'No Maintenance'.
    ENDIF.

    " Description synthétique
    rs_info-description = |{ lv_type_text } { iv_name }|.
    IF lv_ddtext IS NOT INITIAL.
      rs_info-description = rs_info-description && | - { lv_ddtext }|.
    ENDIF.
    IF lv_devclass IS NOT INITIAL.
      rs_info-description = rs_info-description && | in { lv_devclass }|.
    ENDIF.
    rs_info-description = rs_info-description && | [{ lv_maint }]|.
    IF lv_dbrefname IS NOT INITIAL AND lv_dbrefname <> CONV dd25l-dbrefname( lv_viewname ).
      rs_info-description = rs_info-description && | (DB: { lv_dbrefname })|.
    ENDIF.

    " === Tables et conditions de jointure (DD26S) ===
    SELECT * FROM dd26s INTO TABLE @lt_dd26s
      WHERE viewname = @lv_viewname
        AND as4local = 'A'
      ORDER BY tabpos.

    IF lt_dd26s IS NOT INITIAL.
      lv_source = |Join Tables:|.
      LOOP AT lt_dd26s INTO ls_dd26s.
        IF ls_dd26s-fortabname IS INITIAL.
          lv_source = lv_source
            && |{ cl_abap_char_utilities=>newline }  [{ ls_dd26s-tabpos }] { ls_dd26s-tabname } (Primary)|.
        ELSE.
          lv_source = lv_source
            && |{ cl_abap_char_utilities=>newline }  [{ ls_dd26s-tabpos }] { ls_dd26s-tabname }|
            && | ON { ls_dd26s-fortabname }.{ ls_dd26s-forfield }|.
        ENDIF.
      ENDLOOP.
    ENDIF.

    " === Conditions de sélection (DD28S, CONDNAME = VIEWNAME) ===
    SELECT * FROM dd28s INTO TABLE @lt_dd28s
      WHERE condname = @lv_condname
        AND as4local = 'A'
      ORDER BY position.

    IF lt_dd28s IS NOT INITIAL.
      IF lv_source IS NOT INITIAL.
        lv_source = lv_source && cl_abap_char_utilities=>newline.
      ENDIF.
      lv_source = lv_source && |{ cl_abap_char_utilities=>newline }Selection Conditions:|.
      LOOP AT lt_dd28s INTO ls_dd28s.
        CLEAR lv_cond_line.
        IF ls_dd28s-negation IS NOT INITIAL.
          lv_cond_line = |{ ls_dd28s-negation } |.
        ENDIF.
        lv_cond_line = lv_cond_line
          && |{ ls_dd28s-tabname }-{ ls_dd28s-fieldname } { ls_dd28s-operator } '{ ls_dd28s-constants }'|.
        IF ls_dd28s-and_or IS NOT INITIAL.
          lv_cond_line = lv_cond_line && | { ls_dd28s-and_or }|.
        ENDIF.
        lv_source = lv_source
          && |{ cl_abap_char_utilities=>newline }  { lv_cond_line }|.
      ENDLOOP.
    ENDIF.

    rs_info-source = lv_source.

    " === Champs de la vue via DD03L ===
    SELECT fieldname AS field, keyflag AS key, datatype AS type, rollname AS dataelement
      FROM dd03l
      INTO CORRESPONDING FIELDS OF TABLE @lt_comp
      WHERE tabname  = @lv_viewname
        AND as4local = 'A'
      ORDER BY position.

    LOOP AT lt_comp INTO ls_comp.
      lv_fieldname = ls_comp-field.
      SELECT SINGLE * FROM dd03l INTO @ls_dd03l
        WHERE tabname   = @lv_viewname
          AND fieldname = @lv_fieldname
          AND as4local  = 'A'.
      ls_comp-length = ls_dd03l-leng.

      lv_rollname = ls_comp-dataelement.
      SELECT SINGLE ddtext FROM dd04t
        INTO @ls_comp-description
        WHERE rollname   = @lv_rollname
          AND ddlanguage = 'E'
          AND as4local   = 'A'.
      MODIFY lt_comp FROM ls_comp.
    ENDLOOP.

    rs_info-components = lt_comp.
  ENDMETHOD.

ENDCLASS.
