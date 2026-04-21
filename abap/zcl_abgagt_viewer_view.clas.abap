*"*"use source
*"*"Local Interface:
*"**********************************************************************
"! <p class="shorttext synchronized">Viewer pour les vues ABAP (VIEW)</p>
"! Retourne la définition d'une vue ABAP : type de vue, champs, paquet.
CLASS zcl_abgagt_viewer_view DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES zif_abgagt_viewer.

ENDCLASS.

CLASS zcl_abgagt_viewer_view IMPLEMENTATION.

  METHOD zif_abgagt_viewer~get_info.
    DATA: lv_devclass  TYPE tadir-devclass,
          lt_comp      TYPE STANDARD TABLE OF zcl_abgagt_command_view=>ty_component WITH DEFAULT KEY,
          ls_comp      TYPE zcl_abgagt_command_view=>ty_component,
          ls_dd03l     TYPE dd03l,
          lv_viewname  TYPE dd25l-viewname,
          lv_ddtext    TYPE dd25t-ddtext,
          lv_fieldname TYPE dd03l-fieldname,
          lv_rollname  TYPE dd03l-rollname,
          lv_type_text TYPE string,
          lv_viewclass TYPE dd25l-viewclass.

    lv_viewname = iv_name.

    rs_info-name = iv_name.
    rs_info-type = 'VIEW'.

    " Lecture de l'en-tête de la vue dans DD25L
    SELECT SINGLE viewclass FROM dd25l INTO @lv_viewclass
      WHERE viewname = @lv_viewname
        AND as4local = 'A'.

    IF sy-subrc = 0.
      CASE lv_viewclass.
        WHEN 'D'. lv_type_text = 'Database View'.
        WHEN 'P'. lv_type_text = 'Projection View'.
        WHEN 'H'. lv_type_text = 'Help View'.
        WHEN 'M'. lv_type_text = 'Maintenance View'.
        WHEN OTHERS. lv_type_text = 'View'.
      ENDCASE.
      rs_info-type_text = lv_type_text.

      " Texte court de la vue
      SELECT SINGLE ddtext FROM dd25t INTO @lv_ddtext
        WHERE viewname   = @lv_viewname
          AND ddlanguage = 'E'
          AND as4local   = 'A'.

      " Paquet depuis TADIR
      SELECT SINGLE devclass FROM tadir INTO @lv_devclass
        WHERE obj_name = @iv_name
          AND object   = 'VIEW'.

      rs_info-description = |{ lv_type_text } { iv_name }|.
      IF lv_ddtext IS NOT INITIAL.
        rs_info-description = rs_info-description && | - { lv_ddtext }|.
      ENDIF.
      IF lv_devclass IS NOT INITIAL.
        rs_info-description = rs_info-description && | in { lv_devclass }|.
      ENDIF.
    ELSE.
      rs_info-type_text = 'View'.
      rs_info-not_found = abap_true.
    ENDIF.

    " Champs de la vue via DD03L (même approche que TABL/STRU)
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
