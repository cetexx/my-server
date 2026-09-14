<?php
/**
 * Roundcube nustatymai, kurių image'as per aplinkos kintamuosius nepasiekia.
 *
 * Šis failas įtraukiamas PASKUTINIS: entrypoint'as prideda
 * `include('/var/roundcube/config/custom.php');` į config.docker.inc.php galą,
 * tad čia esančios reikšmės perrašo ir defaults.inc.php, ir image'o numatytąsias.
 * Tai oficialus image'o kabliukas — jokių jo failų perrašinėti nereikia.
 */

// --- Rašymas -------------------------------------------------------------
// Numatytoji reikšmė buvo 0 (grynas tekstas), ir būtent dėl to laiškai bei
// atsakymai atrodydavo pliki: jokio šrifto, spalvų, lentelių ar parašo su
// logotipu. TinyMCE image'e yra, tik nebuvo įjungtas.
$config['htmleditor'] = 1;
$config['default_font'] = 'Arial';
$config['default_font_size'] = '11pt';

// Atsakymas rašomas VIRŠ cituojamo teksto — taip, kaip įprasta susirašinėjant
// verslo laiškais (ir taip, kaip daro Outlook bei Gmail).
$config['reply_mode'] = 1;

// Ilgą citatų grandinę sutraukia į „...", kad atsakymo pradžia nepaskęstų.
// Veikia tik su hide_blockquote plugin'u, todėl riba nurodoma čia.
$config['hide_blockquote_limit'] = 12;

// --- Sąsaja ---------------------------------------------------------------
$config['layout'] = 'widescreen';   // trys stulpeliai: aplankai / sąrašas / laiškas
$config['mail_pagesize'] = 50;
$config['addressbook_pagesize'] = 50;
$config['message_show_email'] = true;  // rodyti ir adresą, ne tik vardą
$config['prefer_html'] = true;

// Įdiegimo vedlys produkcijoje neturi būti pasiekiamas.
$config['enable_installer'] = false;
