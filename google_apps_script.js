/**
 * Google Apps Script for MacDeck Feedback Form
 * Spreadsheet: https://docs.google.com/spreadsheets/d/1iooynZQSkNZUCJauCPIvHEihta7BP8OQykW62kms35Y/edit
 * 
 * Instructions to enable real-time cloud sync:
 * 1. Open your Google Sheet (link above).
 * 2. In the top menu, click: Extensions -> Apps Script.
 * 3. Delete any existing code and paste this entire file.
 * 4. Click 'Deploy' (top right) -> 'New deployment'.
 * 5. Select type: 'Web app'.
 * 6. Set Description: "MacDeck Feedback Webhook".
 * 7. Set "Execute as": "Me".
 * 8. Set "Who has access": "Anyone".
 * 9. Click 'Deploy' and copy the generated Web App URL!
 */

function doPost(e) {
  try {
    var sheet = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
    
    // Auto-create header row if sheet is empty
    if (sheet.getLastRow() === 0) {
      sheet.appendRow([
        "Timestamp",
        "Type",
        "Title / Summary",
        "Sender Name",
        "Email",
        "Device & OS",
        "Message / Details"
      ]);
      // Style header row
      var headerRange = sheet.getRange(1, 1, 1, 7);
      headerRange.setFontWeight("bold");
      headerRange.setBackground("#18181b");
      headerRange.setFontColor("#ffffff");
    }

    var data;
    if (e.postData && e.postData.contents) {
      data = JSON.parse(e.postData.contents);
    } else {
      data = e.parameter;
    }

    var timestamp = data.timestamp || new Date().toLocaleString();
    var type = (data.type || "question").toUpperCase();
    var title = data.title || "Untitled";
    var sender = data.sender || "Anonymous";
    var email = data.email || "";
    var device = data.device || "";
    var message = data.message || "";

    // Append new row
    sheet.appendRow([
      timestamp,
      type,
      title,
      sender,
      email,
      device,
      message
    ]);

    // Format new row
    var lastRow = sheet.getLastRow();
    var typeCell = sheet.getRange(lastRow, 2);
    if (type.indexOf("BUG") !== -1) {
      typeCell.setFontColor("#FF453A").setFontWeight("bold");
    } else if (type.indexOf("FEATURE") !== -1) {
      typeCell.setFontColor("#30D158").setFontWeight("bold");
    } else {
      typeCell.setFontColor("#0A84FF").setFontWeight("bold");
    }

    return ContentService.createTextOutput(JSON.stringify({
      status: "success",
      message: "Row added to Google Sheet successfully",
      row: lastRow
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (error) {
    return ContentService.createTextOutput(JSON.stringify({
      status: "error",
      message: error.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

function doGet(e) {
  return ContentService.createTextOutput(JSON.stringify({
    status: "online",
    sheet: "MacDeck Feedback Hub",
    timestamp: new Date().toISOString()
  })).setMimeType(ContentService.MimeType.JSON);
}
