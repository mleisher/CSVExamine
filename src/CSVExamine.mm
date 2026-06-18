//
// CSVExamine — nextpad++ plugin
// Original: © 2026 Mark Leisher <mleisher@duck.com>
//
// Provides some simple visualization tools for CSV files.
//
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <iostream>
#include <map>
#include <regex>
#include <vector>
#include <functional>

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

static const char *PLUGIN_NAME = "CSVExamine";
static const int NB_FUNC = 6;
static FuncItem funcItem[NB_FUNC];
NppData nppData;

// The list of the escaped characters that might be in configuration values.
const std::unordered_map<std::string, std::string> escapedChars = {
  {"\\t", "\t"},
  {"\\n", "\n"},
  {"\\r", "\r"},
  {"\\\"", "\""}
};

/******************************************************************************/

//
// Classes.
//

class CSVExamineGlobals {
 private:
  std::unordered_map<std::string, std::reference_wrapper<std::string>> fieldMap;
  NSRegularExpression *boolTruePat;

  //
  // Break the string into a list of UTF-8 characters.
  //
  void strToList(std::string s, std::vector<const char *>& list, bool debug = false) {
    if (delimiterList.size() > 0 || encloserList.size() > 0)
      // No need to break them up again.
      return;

    NSString *utf8 = [NSString stringWithUTF8String:s.c_str()];
    if (!utf8) return;
    [utf8 enumerateSubstringsInRange:NSMakeRange(0, [utf8 length])
			      options:NSStringEnumerationByComposedCharacterSequences
			   usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
	if (substring)
	  list.push_back(strdup([substring UTF8String]));
      }];
  }

 public:
  std::vector<const char *> delimiterList;
  std::vector<const char *> encloserList;
  std::string delimiters = ",;\t|:~^";
  std::string enclosers = "\"'";
  bool selectColumn = true;
  NSMenuItem *plugin = NULL, *clipboard = NULL;

  CSVExamineGlobals() {
    //
    // Create a map that provides references to the internal fields to avoid lots of string comparisons
    // while assigning values to them.
    //
    fieldMap.insert({"commonDelimiters", std::ref(delimiters)});
    fieldMap.insert({"commonEnclosers", std::ref(enclosers)});

    // Create the regex pattern that will be used to check the 'clickToHighlightColumn' value.
    NSError *error;
    boolTruePat = [NSRegularExpression
		    regularExpressionWithPattern:@"(true|1)"
					 options:NSRegularExpressionCaseInsensitive error:&error];
  }

  NSString *updateField(std::string attr, std::string value) {
    if (attr == "clickToSelectColumn") {
      NSRange range = NSMakeRange(0, value.length());
      selectColumn = ([boolTruePat firstMatchInString:@(value.c_str()) options:0 range:range]) ? true : false;
    } else {
      try {
	// Go through and replace all instances of the escaped characters with their actual values.
	for (const auto& pair: escapedChars) {
	  size_t startPos = 0;
	  while ((startPos = value.find(pair.first)) != std::string::npos) {
	    value.replace(startPos, pair.first.length(), pair.second);
	    startPos += pair.second.length();
	  }
	}
	fieldMap.at(attr).get() = value;
      } catch (std::out_of_range &e) {
	return [NSString stringWithFormat:@"Unknown global parameter '%@'.\n", @(attr.c_str())];
      }
      return NULL;
    }
    return NULL;
  }

  //
  // Split the delimiters and enclosers into lists.
  //
  void makeLists() {
    strToList(delimiters, delimiterList);
    strToList(enclosers, encloserList);
  }

  NSString *toNSString() {
    std::string s = "[Globals]\ncommonDelimiters = \"" + delimiters +
      "\"\ncommonEnclosers = \"" + enclosers +
      "\"\nclickToHighlightColumn = \"" + (selectColumn ? "true" : "false") + "\"";
    return [NSString stringWithFormat:@"%s\n", s.c_str()];
  }

  friend std::ostream& operator<<(std::ostream& os, const CSVExamineGlobals& ceg) {
    return os << "[Globals]\ncommonDelimiters = \"" << ceg.delimiters
	      << "\"\ncommonEnclosers = \"" << ceg.enclosers << "\"\nhighlightColumns = \"" << ceg.selectColumn << "\"\n";
  }
};

class CSVExamineFormat {
 private:
  std::unordered_map<std::string, std::reference_wrapper<std::string>> fieldMap;

 public:
  std::string name;
  std::string delimiter;
  std::string encloseWith;
  std::string tooltipFormat;
  std::string coordinatesFormat;
  // Booleans telling us which values are expected in the tooltip.
  bool headerTooltip;
  bool coordsTooltip;

  // All CSVExamineFormat classes are initialized with the standard defaults.
  // They can be overridden in CSVExamine.ini file.
 CSVExamineFormat(std::string name = "Comma") : name(name) {
    delimiter = ",";
    encloseWith = "\"";
    tooltipFormat = "@Header (@Coordinates)";
    coordinatesFormat = "A1";
    headerTooltip = false;
    coordsTooltip = false;

    //
    // Create a map that provides references to the internal fields to avoid lots of string comparisons
    // while assigning values to them.
    //
    fieldMap.insert({"name", std::ref(name)});
    fieldMap.insert({"delimiter", std::ref(delimiter)});
    fieldMap.insert({"encloseWith", std::ref(encloseWith)});
    fieldMap.insert({"tooltipFormat", std::ref(tooltipFormat)});
    fieldMap.insert({"coordinatesFormat", std::ref(coordinatesFormat)});
  }

  NSString *updateField(std::string attr, std::string value) {
    try {
      fieldMap.at(attr).get() = value;
    } catch (std::out_of_range &e) {
      return [NSString stringWithFormat:@"Unknown configuration parameter '%@'.\n", @(attr.c_str())];
    }

    return NULL;
  }

  //
  // Parse the tooltipFormat string to find out what values are needed.
  //
  void parseTooltipFormat() {
    // If this is the tooltip format string, check to see which values are expected.
    if (tooltipFormat.find("@Header") != std::string::npos)
      headerTooltip = true;
    if (tooltipFormat.find("@Coordinates") != std::string::npos)
      coordsTooltip = true;
  }

  NSString *toNSString() {
    std::string s = "[" + name + "]\ndelimiter = \"" + delimiter + "\"\nencloseWith = \"" + encloseWith +
      "\"\ncoordinatesFormat = \"" + coordinatesFormat + "\"\ntooltipFormat = \"" + tooltipFormat + "\"";
    return [NSString stringWithFormat:@"%s\n", s.c_str()];
  }
  friend std::ostream& operator<<(std::ostream& os, const CSVExamineFormat& cef) {
    return os << "[" << cef.name << "]\ndelimiter = \"" << cef.delimiter
	      << "\"\nencloseWith = \"" << cef.encloseWith << "\"\ncoordinatesFormat = \"" << cef.coordinatesFormat
	      << "\"\ntooltipFormat = \"" << cef.tooltipFormat << "\"\n";
  }
};

class CSVExamineBuffer {
 public:
  // The Scintilla buffer ID.
  NSUInteger id;

  // The CSV format of the buffer contents.
  CSVExamineFormat *format;

  // Current column in the buffer.
  int column;

  // The custom indicator for the buffer.
  int indicator;

  // List of position and length pairs of selected cells.
  std::vector<std::pair<int,int>> indicatorLocations;

  // The largest indicator length in the locations list.
  int maxIndicatorLen;

  // The state of the selectColumn flag for this buffer.
  bool selectColumn;

  CSVExamineBuffer() {
    id = 0;
    format = NULL;
    column = indicator = -1;
    maxIndicatorLen = 0;
    selectColumn = false;
  }
};

/******************************************************************************/

//
// Global CSV values.
//
static bool g_LoadingGlobals = false;
static CSVExamineGlobals g_Globals;

/******************************************************************************/

//
// Buffers and views.
//

// The list of buffer IDs (for CSV files) and their associated formats.
static std::unordered_map<NSUInteger, CSVExamineBuffer *> bufferList;

// The current buffer.
static CSVExamineBuffer *g_CurrentBuffer = NULL;

// The current view.
static int g_CurrentView = -1;

/******************************************************************************/

//
// CSV formats.
//

// The list of formats loaded from the config file.
static std::vector<CSVExamineFormat *> formatList { new CSVExamineFormat() };

/******************************************************************************/

//
// Configuration file.
//

#define MAX_PATH 260

// The config file path.
static char g_charPath[MAX_PATH] {};
static char *g_configPath = NULL;

// Any error messages that happen from loading the config file.
static NSString *g_ConfigLoadErrors = @"";

/******************************************************************************/

//
// Log file (for debugging).
//

// The logfile name.
static const char *g_LogFile = "/tmp/csvexamine.log";

/******************************************************************************/

//
// Handle for the NSEvent local monitor that intercepts button press.
// Installed in NPPN_READY, removed in NPPN_SHUTDOWN.
//
static id g_ButtonEventMonitor = nil;

//
// Declare them early so they can be used.
//
static void addButtonEventMonitor();
static void removeButtonEventMonitor();

//
// Log to the file specified in the config file.
//
static void logit(NSString *msg) {
  NSString *path = @(g_LogFile);
  NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
  if (out) {
    [out seekToEndOfFile];
    [out writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
    [out closeFile];
  } else
    [[msg dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
}

//
// Helpers
//
static NppHandle getCurrentScintilla() {
  int which = -1;
  nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
  return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
  return nppData._sendMessage(h, msg, w, l);
}

static intptr_t sci(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
  return sci(getCurrentScintilla(), msg, w, l);
}

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
  return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

//
// User alerts.
//
static void showAlert(NSString *title, NSString *message) {
  @autoreleasepool {
    CGFloat alertBodySize = [NSFont smallSystemFontSize];
    NSFont *alertBodyFont = [NSFont systemFontOfSize:alertBodySize];
    NSDictionary *attrs = @{NSFontAttributeName:alertBodyFont};
    CGSize stringSize;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message ?: @"";
    //
    // Widen the alert frame a little to accomodate longer messages.
    //
    stringSize = [alert.informativeText sizeWithAttributes:attrs];
    NSView *dummy = [[NSView alloc] initWithFrame:NSMakeRect(0,0,stringSize.width,0)];
    [alert setAccessoryView:dummy];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

//
// Menu callbacks
//
static void showAbout() {
  showAlert(@"CSVExamine v1.0.0 (macos)",
	    @"CSV inspection tools for Nextpad++.\n");
}

//
// Clears all of the highlighted column values.
//
static void clearColumn() {
  int numberCleared = 0;
  sci(getCurrentScintilla(), SCI_SETINDICATORCURRENT, g_CurrentBuffer->indicator);
  for (auto &loc:g_CurrentBuffer->indicatorLocations) {
    sci(getCurrentScintilla(), SCI_INDICATORCLEARRANGE, loc.first, loc.second - loc.first);
    numberCleared++;
  }
  g_CurrentBuffer->indicatorLocations.clear();
  g_CurrentBuffer->maxIndicatorLen = 0;
}

//
// [UTF-8 Helper]: Functions to see if we are looking at an exact match of the string at a position.
//
static bool utf8LookingAt(int pos, const char *delim, int delimLen) {
  NppHandle h = getCurrentScintilla();

  sci(h, SCI_SETTARGETSTART, pos);
  sci(h, SCI_SETTARGETEND, pos + delimLen);

  int matchPos = (int) sci(h, SCI_SEARCHINTARGET, delimLen, (sptr_t) delim);

  return matchPos == pos;
}

static bool utf8LookingAt(int pos, std::string str) {
  return utf8LookingAt(pos, str.c_str(), str.length());
}

static void selectColumn() {
  //
  // Don't to anything if there is no column number or if the plugin is inactive.
  //
  if (g_CurrentBuffer->column < 0 || !g_CurrentBuffer->selectColumn)
    return;

  NppHandle h = getCurrentScintilla();
  int nlines = (int) sci(h, SCI_GETLINECOUNT);
  int i, start, end, llen, column, level = 0, delimLen = g_CurrentBuffer->format->delimiter.length();
  bool done;

  for (int line = 0; line < nlines - 1; line++) {
    llen = (int) sci(h, SCI_LINELENGTH, line);
    start = (int) sci(h, SCI_POSITIONFROMLINE, line);
    int line_end = start + llen;

    //
    // Locate the start position for the column.
    //

    // Get the step value to the next UTF-8 character.
    int step = (int) sci(h, SCI_POSITIONRELATIVE, start, 1);

    for (i = start, column = 0, level = 0; column < g_CurrentBuffer->column && i < line_end; i += step) {
      if (utf8LookingAt(i, g_CurrentBuffer->format->encloseWith))
	level++;
      if (utf8LookingAt(i, g_CurrentBuffer->format->delimiter)) {
	if ((level & 1) == 0) {
	  column++;
	  //
	  // Set the position of the character after the delimiter.
	  //
	  start = i + delimLen;
	  if (column < g_CurrentBuffer->column)
	    step = delimLen;
	  else
	    break;
	}
      } else
	// Need to step over the current UTF-8 character to the next.
	step = (int) sci(h, SCI_POSITIONRELATIVE, i, 1) - i;
    }

    int firstEncloserPos = -1, lastEncloserPos = -1;

    //
    // Locate the end position for the column.
    //

    // Get the step value to the next UTF-8 character.
    step = (int) sci(h, SCI_POSITIONRELATIVE, start, 1);

    for (end = start, level = 0; end < line_end; end += step) {
      if (utf8LookingAt(end, g_CurrentBuffer->format->encloseWith)) {
	if (end == start)
	  firstEncloserPos = start;
	else
	  lastEncloserPos = end;
	level++;
      }
      if (utf8LookingAt(end, g_CurrentBuffer->format->delimiter)) {
	if ((level & 1) == 0)
	  break;
      }
      // Need to step over the current UTF-8 character to the next.
      step = (int) sci(h, SCI_POSITIONRELATIVE, end, 1) - end;
    }

    if (start < end) {
      // Check to see if the value has enclosers, and adjust so the indicator only includes the actual value.
      if (lastEncloserPos > firstEncloserPos && lastEncloserPos == end - step) {
	start += step;
	end -= step;
      }
      sci(h, SCI_SETINDICATORCURRENT, g_CurrentBuffer->indicator);
      sci(h, SCI_INDICATORFILLRANGE, start, end - start);
      g_CurrentBuffer->indicatorLocations.push_back({start, end});
      if (end - start > g_CurrentBuffer->maxIndicatorLen)
	g_CurrentBuffer->maxIndicatorLen = end - start;
    }
  }

  // Enable the Copy To Clipboard menu item if there is something to copy.
  if (g_CurrentBuffer->indicatorLocations.size() > 0)
    [g_Globals.clipboard setEnabled:YES];
}

//
// Detect the format of the CSV file in the buffer by parsing the first three lines for known delimiters.
//
static CSVExamineFormat *detectFormat(char *path) {
  NppHandle h = getCurrentScintilla();
  std::unordered_map<const char *, int> delimiterCounts;
  int lno, start, end, column, level, llen, line_end, step = 1, delimLen;

  // Scan the first three lines of text for possible delimiters.
  for (lno = 0; lno < 3; lno++) {
    start = (int) sci(h, SCI_POSITIONFROMLINE, lno);
    llen = (int) sci(h, SCI_LINELENGTH, lno);
    line_end = start + llen;

    for (int pos = start; pos < line_end; pos += step) {
      bool found;
      for (int s = 0, found = false; s < g_Globals.delimiterList.size() && !found; s++) {
	const char *delim = g_Globals.delimiterList[s];
	delimLen = strlen(delim);

	if (delimLen == step && utf8LookingAt(pos, delim, delimLen)) {
	  //
	  // The delimiter matched. Increment the count.
	  //
	  if (delimiterCounts.count(delim) > 0)
	    delimiterCounts[delim]++;
	  else
	    delimiterCounts[delim] = 1;
	  found = true;
	  step = delimLen;
	}
      }
      if (!found)
	// Need to step over the current UTF-8 character in the line to the next.
	step = (int) sci(h, SCI_POSITIONRELATIVE, pos, 1) - pos;
    }
  }
  // Find the delimiter with the max count.
  if (!delimiterCounts.empty()) {
    auto maxCount = std::max_element(delimiterCounts.begin(), delimiterCounts.end(),
				     [](const auto& p1, const auto& p2) { return p1.second < p2.second; });

    std::string sep = maxCount->first;

    // Find the format that matches the found delimiter and make it current.
    for (int i = 0; i < formatList.size(); i++) {
      if (formatList[i]->delimiter == sep)
	return formatList[i];
    }
  }
  return NULL;
}

//
// Check if the buffer is a CSV file. If it is, parse a few lines to determine format.
//
static void handleBufferChange(NppHandle h, NSUInteger bufferID, int view) {
  CSVExamineBuffer *buffer = NULL;

  if (g_CurrentBuffer != NULL) {
    if (g_CurrentBuffer->id == bufferID)
      return;
  }

  // Set the current view, no matter what buffer is active.
  g_CurrentView = view;

  if (bufferList.count(bufferID) > 0) {
    g_CurrentBuffer = bufferList[bufferID];
  } else {
    //
    // The bufferID has not been seen yet. Check if this is a new view on an existing buffer.
    //
    if (view == 1) {
      if (bufferList.count(bufferID) == 0) {
	bufferList[bufferID] = g_CurrentBuffer;
	sci(h, SCI_SETBIDIRECTIONAL, SC_BIDIRECTIONAL_L2R, 0);
	sci(h, SCI_INDICSETSTYLE, g_CurrentBuffer->indicator, INDIC_ROUNDBOX);
	sci(h, SCI_INDICSETFORE, g_CurrentBuffer->indicator, 0x0000ff);
      }
    } else {
      char bpath[MAX_PATH] = {0};

      // Get the filename from the buffer so we can check the extension.
      nppData._sendMessage(nppData._nppHandle, NPPM_GETFILENAME,
			   (uintptr_t) bufferID, (intptr_t)bpath);
      if ([[@(bpath) pathExtension] caseInsensitiveCompare:@"csv"] == NSOrderedSame) {
	// Add it to the bufferList only if it's a CSV file.
	buffer = new CSVExamineBuffer();
	buffer->id = bufferID;
	buffer->selectColumn = g_Globals.selectColumn;

	// Create the custom indicator for the buffer.
	NppHandle h = getCurrentScintilla();
	nppData._sendMessage(nppData._nppHandle, NPPM_ALLOCATEINDICATOR, 1, (intptr_t) &buffer->indicator);
	sci(h, SCI_INDICSETSTYLE, buffer->indicator, INDIC_ROUNDBOX);
	sci(h, SCI_INDICSETFORE, buffer->indicator, 0x0000ff);

	buffer->format = detectFormat(bpath);
	bufferList[bufferID] = buffer;

	if (buffer->format == NULL)
	  showAlert(@"Format Alert", [NSString stringWithFormat:@"Format for CSV file '%s' undetermined.\n\nDo one of:\n1. Select an existing format from the %s 'Format' menu.\n2. Add a format to the .ini file and restart.\n3. Add the custom delimiter to the 'commonDelimiters' parameter in the .ini file and restart.", bpath, PLUGIN_NAME]);
	g_CurrentBuffer = buffer;
      } else {
	// Not a .csv file. Disable the CSVExamine menu entry.
	g_CurrentBuffer = NULL;
	[g_Globals.plugin setEnabled:NO];
      }
    }
  }
  if (g_CurrentBuffer != NULL) {
    // Set the state of the Copy To Clipboard menu item and whether the Select Column
    // menu item is checked.
    npp(NPPM_SETMENUITEMCHECK, funcItem[2]._cmdID, g_CurrentBuffer->selectColumn ? 1 : 0);

    if (g_Globals.clipboard != NULL) {
      [g_Globals.plugin setEnabled:YES];
      if (g_CurrentBuffer->selectColumn && g_CurrentBuffer->indicatorLocations.size() > 0)
	[g_Globals.clipboard setEnabled:YES];
      else
	[g_Globals.clipboard setEnabled:NO];
    }
  }
}

static void toggleSelectColumn() {
  g_CurrentBuffer->selectColumn = !g_CurrentBuffer->selectColumn;
  npp(NPPM_SETMENUITEMCHECK, funcItem[2]._cmdID, g_CurrentBuffer->selectColumn ? 1 : 0);

  //
  // Add or remove the button click monitor as needed.
  //
  if (g_CurrentBuffer->selectColumn)
    addButtonEventMonitor();
  else {
    removeButtonEventMonitor();

    // Hide any call tips that are visible.
    sci(getCurrentScintilla(), SCI_CALLTIPCANCEL);

    // Clear any selected column.
    clearColumn();

    // Disable the Copy To Clipboard menu item.
    [g_Globals.clipboard setEnabled:NO];
  }
}

//
// Config file loading/saving.
//
static BOOL haveConfigFile() {
  if (g_configPath != NULL) return YES;

  NSUInteger size =
    (NSUInteger) nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, MAX_PATH, (LPARAM)g_charPath);
  NSString *configPath = [[NSString alloc] initWithUTF8String:g_charPath];
  configPath = [configPath stringByAppendingString:@"/CSVExamine.ini"];

  //
  // If the config file doesn't exist, copy it from the installation location.
  //
  if (![[NSFileManager defaultManager] fileExistsAtPath:configPath]) {
    memset(g_charPath, 0, sizeof(g_charPath));
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINHOMEPATH, MAX_PATH, (LPARAM) g_charPath);
    NSString *configSrcPath = [[NSString alloc] initWithUTF8String:g_charPath];
    configSrcPath = [configSrcPath stringByAppendingString:@"/CSVExamine/CSVExamine.ini"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:configSrcPath]) {
      NSError *error = nil;
      BOOL success = [[NSFileManager defaultManager] copyItemAtPath:configSrcPath toPath:configPath error:&error];
      if (!success)
	showAlert(@"Config File Copy", [NSString stringWithFormat:@"Unable to copy from '%@' to '%@'.\n\nError Details: %@",
						 configSrcPath, configPath, [error localizedDescription]]);
      else {
	g_configPath = strdup([configPath UTF8String]);
	return YES;
      }
    } else
      showAlert(@"Config File", [NSString stringWithFormat:@"The config file '%@' does not exist.\n\nUsing default values for delimiter and encloser.", configPath]);
    return NO;
  }
  g_configPath = strdup([configPath UTF8String]);
  return YES;
}

//
// Open the config file for editing.
//
static void editConfig() {
  if (haveConfigFile())
    npp(NPPM_DOOPEN, 0, (intptr_t) g_configPath);
}

//
// Copy the highlighted column to the clipboard.
//
static void copyColumnToClipboard(std::string sep = "\n") {
  if (!g_CurrentBuffer->selectColumn) return;

  NppHandle h = getCurrentScintilla();
  NSString *segment = NULL;
  NSMutableString *column = [NSMutableString string];

  // Allocate space for the longest indicator in the column so we don't have to do
  // hundreds or thousands of allocations to get all the text highlighted by the indicators.
  Sci_TextRangeFull irange;
  irange.lpstrText = (char *) malloc(g_CurrentBuffer->maxIndicatorLen + 1);

  int count = 0;
  for (auto const& pair : g_CurrentBuffer->indicatorLocations) {
    irange.chrg.cpMin = pair.first;
    irange.chrg.cpMax = pair.second;
    if (sci(h, SCI_GETTEXTRANGEFULL, 0, (LPARAM)&irange) != -1) {
      irange.lpstrText[pair.second] = 0;
      segment = [NSString stringWithUTF8String:irange.lpstrText];
      if ([column length] > 0)
	[column appendFormat:@"%s", sep.c_str()];
      if (segment)
	[column appendString:segment];
    }
    count++;
  }
  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard setString:column forType:NSPasteboardTypeString];
}

static void columnToClipboard() {
  copyColumnToClipboard();
}
static void columnToClipboardAsRow() {
  copyColumnToClipboard(g_CurrentBuffer->format->delimiter);
}

static void getColumnNumber(int pos) {
  NppHandle h = getCurrentScintilla();
  int lno     = (int) sci(h, SCI_LINEFROMPOSITION, pos);
  int lstart  = (int) sci(h, SCI_POSITIONFROMLINE, lno);
  int level   = 0;

  g_CurrentBuffer->column = 0;

  //
  // Calculate the column number.
  //
  for (int i = lstart; i < pos; i++) {
    if (utf8LookingAt(i, g_CurrentBuffer->format->encloseWith))
      level++;
    if (utf8LookingAt(i, g_CurrentBuffer->format->delimiter) && (level & 1) == 0)
      g_CurrentBuffer->column++;
  }
}

static char alpha[] = " ABCDEFGHIJKLMNOPQRSTUVWXYZ";

static std::string columnNumberToLabel(int col) {
  std::string s = "";
  int m, ri = 4;
  while (col > 0) {
    m = col % 26;
    if (m == 0) {
      m = 26;
      col--;
    }
    s = alpha[m] + s;
    col = std::round(col / 26);
  }
  return s;
}

//
// Get the column header text.
//
static NSString *getColumnHeaderText(int position, int lno) {
  NppHandle h = getCurrentScintilla();
  int i, start, end, column, level, line_end, step, delimLen;
  NSString *res = nil;
  Sci_TextRangeFull header;
  
  line_end = (int) sci(h, SCI_LINELENGTH, 0);
  delimLen = g_CurrentBuffer->format->delimiter.length();

  //
  // Find the start of the column text.
  //
  for (i = start = 0, column = 0, level = 0; column < g_CurrentBuffer->column && i < line_end - 1; i += step) {
    if (utf8LookingAt(i, g_CurrentBuffer->format->encloseWith))
      level++;
    if (utf8LookingAt(i, g_CurrentBuffer->format->delimiter)) {
      if ((level & 1) == 0) {
	column++;
	//
	// Set the position of the character after the delimiter.
	//
	start = i + delimLen;
	if (column < g_CurrentBuffer->column)
	  step = delimLen;
	else
	  break;
      }
    } else
      // Need to step over the current UTF-8 character to the next.
      step = (int) sci(h, SCI_POSITIONRELATIVE, i, 1) - i;
  }

  //
  // Get the end of the column text.
  //
  for (end = start, level = 0; end < line_end - 1; end += step) {
    if (utf8LookingAt(end, g_CurrentBuffer->format->encloseWith))
      level++;
    if (utf8LookingAt(end, g_CurrentBuffer->format->delimiter)) {
      if ((level & 1) == 0)
	break;
    }
    // Need to step over the current UTF-8 character to the next.
    step = (int) sci(h, SCI_POSITIONRELATIVE, end, 1) - end;
  }

  if (start == end)
    return nil;

  header.chrg.cpMin = start;
  header.chrg.cpMax = end;
  header.lpstrText = new char[end - start + 1];

  // If header text is found.
  if (sci(h, SCI_GETTEXTRANGEFULL, 0, (LPARAM)&header) != -1)
    res = [NSString stringWithFormat:@"%s", header.lpstrText];
  return res;
}

static void handleTooltip(int position) {
  if (g_CurrentBuffer == NULL || g_CurrentBuffer->format == NULL)
    return;

  //
  // First, hide any call tip that is visible.
  //
  NppHandle h = getCurrentScintilla();

  if (position < 0)
    return;

  int lno = (int) sci(h, SCI_LINEFROMPOSITION, position);

  // Calculate the column number.
  getColumnNumber(position);

  NSString *hdr = nil;
  NSString *coords = nil;

  if (g_CurrentBuffer->format->headerTooltip)
    hdr = getColumnHeaderText(position, lno);
  if (g_CurrentBuffer->format->coordsTooltip) {
    if (g_CurrentBuffer->format->coordinatesFormat == "" || g_CurrentBuffer->format->coordinatesFormat == "A1")
      coords = [NSString stringWithFormat:@"%s%d", columnNumberToLabel(g_CurrentBuffer->column + 1).c_str(), lno + 1];
    else
      coords = [NSString stringWithFormat:@"R%dC%d", lno + 1, g_CurrentBuffer->column + 1];
  }

  // Get the tooltip format string and replace the variables with their values.
  if (g_CurrentBuffer->format->headerTooltip || g_CurrentBuffer->format->coordsTooltip) {
    NSString *tt = [NSString stringWithUTF8String:g_CurrentBuffer->format->tooltipFormat.c_str()];

    if (g_CurrentBuffer->format->headerTooltip)
      tt = [tt stringByReplacingOccurrencesOfString:@"@Header" withString:hdr];
    if (g_CurrentBuffer->format->coordsTooltip)
      tt = [tt stringByReplacingOccurrencesOfString:@"@Coordinates" withString:coords];

    // Show the tooltip.
    sci(h, SCI_CALLTIPSHOW, position, (intptr_t) [tt UTF8String]);
  }
}

static void addButtonEventMonitor() {
  if (g_ButtonEventMonitor) return;

  g_ButtonEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
							       handler:^NSEvent * _Nullable(NSEvent *event) {
      // No modifier keys with the click.
      NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
      if (mods != 0) return event;

      // Don't bother if there is no format.
      if (g_CurrentBuffer->format == NULL) return event;

      if (g_CurrentBuffer->selectColumn) {
	int pos = (int) sci(getCurrentScintilla(), SCI_GETCURRENTPOS);
	clearColumn();
	getColumnNumber(pos);
	selectColumn();
      }
      return event;
    }];
}

static void removeButtonEventMonitor() {
    if (!g_ButtonEventMonitor) return;
    [NSEvent removeMonitor:g_ButtonEventMonitor];
    g_ButtonEventMonitor = nil;
}

//
// A FormatChooser object that is called with the NSMenuItem that was clicked.
//
@interface FormatChooser : NSObject
- (void) chooseFormat:(id)sender;
@end
@implementation FormatChooser
- (void)chooseFormat:(id)sender {
  NSMenuItem *item = (NSMenuItem *) sender;
  id rov = [item representedObject];
  if ([rov isKindOfClass:[NSNumber class]])
    g_CurrentBuffer->format = formatList[[rov unsignedIntegerValue]];
}
@end

static void formatMenu() {
  @autoreleasepool {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Formats"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Formats" action:NULL keyEquivalent:@""];
    [item setEnabled:NO];
    [menu addItem:item];
    [menu addItem:[NSMenuItem separatorItem]];

    for (NSUInteger i = 0; i < formatList.size(); i++) {
      CSVExamineFormat *fmt = formatList[i];
      item = [[NSMenuItem alloc] initWithTitle:@(fmt->name.c_str()) action:@selector(chooseFormat:) keyEquivalent:@""];
      [item setTarget:[[FormatChooser alloc] init]];
      [item setRepresentedObject:@(i)];
      NSString *desc = [NSString stringWithFormat:@"delimiter: %s\nencloseWith: %s\ncoordinatesFormat: %s\ntooltipFormat: %s",
				 fmt->delimiter.c_str(),fmt->encloseWith.c_str(),
				 fmt->coordinatesFormat.c_str(),fmt->tooltipFormat.c_str()];
      [item setToolTip:desc];

      //
      // Set the checkmark on the current format.
      //
      if (g_CurrentBuffer != NULL && g_CurrentBuffer->format == formatList[i])
	[item setState:NSControlStateValueOn];
      [menu addItem:item];
    }

    [menu popUpMenuPositioningItem:nil atLocation:[NSEvent mouseLocation] inView:nil];
  }
}

static NSString *getAndTrimMatch(NSString *str, NSRange range) {
  return [[str substringWithRange:range] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

//
// Function used to parse values from the config file and assign them to the format object.
//
static NSString *assignAttributeValue(std::string attr, std::string value, CSVExamineFormat *fmt) {
  if (attr.empty()) return NULL;

  if (value.empty() || value.length() == 0)
    return [NSString stringWithFormat:@"No value provided for '%@'\n", @(attr.c_str())];
    
  if (value[0] != '"' || value[value.length() - 1] != '"')
    return [NSString stringWithFormat:@"Missing one or both enclosers around value of '%@ = %@'.\n",
		     @(attr.c_str()), @(value.c_str())];

  // Remove the enclosing double quotes.
  value.erase(0,1);
  value.pop_back();

  // Go through and replace all instances of the escaped characters with their actual values.
  for (const auto& pair: escapedChars) {
    size_t startPos = 0;
    while ((startPos = value.find(pair.first)) != std::string::npos) {
      value.replace(startPos, pair.first.length(), pair.second);
      startPos += pair.second.length();
    }
  }

  //
  // Assign to the current format or the globals.
  //
  return (fmt) ? fmt->updateField(attr, value) : g_Globals.updateField(attr, value);
}

static void loadConfig() {
  if (!haveConfigFile()) return;

  NSUInteger lineno = 0;
  NSError *error;
  NSString *configFile = [NSString stringWithUTF8String:g_configPath];
  NSString *contents = [NSString stringWithContentsOfFile:configFile encoding:NSUTF8StringEncoding error:&error];
  if (!contents) {
    showAlert(@"Load Configuration",[NSString stringWithFormat:@"Problem loading config file '%s'.\n\nError Details: %@",
					      g_configPath, [error localizedDescription]]);
    return;
  }
  NSArray *lines = [contents componentsSeparatedByString:@"\n"];

  //
  // Avoid parsing if the file is empty.
  //
  if (lines.count == 0) return;

  //
  // Expression to find lines that should be skipped.
  //
  NSRegularExpression *skipPat = [NSRegularExpression regularExpressionWithPattern:@"^(\\s+$|;)" options:0 error:&error];
  NSRegularExpression *formatPat = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[([^\\]]+)\\]"
									      options:0 error:&error];
  NSRegularExpression *generalPat = [NSRegularExpression regularExpressionWithPattern:@"^\\s*([^=\\s\"]+)\\s*=\\s*(.*)$"
									      options:0 error:&error];
  CSVExamineFormat *fmt = NULL;

  for (NSString *line in lines) {
    NSUInteger len = [line length];
    NSRange range = NSMakeRange(0, len);
    NSTextCheckingResult *match;
    NSString *name, *value, *err;

    lineno++;

    // Skip empty lines.
    if (len == 0)
      continue;

    // Skip any line that start with a comment character ';' or is all whitespace.
    if ([skipPat firstMatchInString:line options:0 range:range])
      continue;

    // Handle format identifiers (e.g. [Semicolon]).
    if ((match = [formatPat firstMatchInString:line options:0 range:range])) {
      if (match.numberOfRanges > 1) {

	// Create the new format and add it to the list.
	NSString *val = getAndTrimMatch(line, [match rangeAtIndex:1]);
	if ([val caseInsensitiveCompare:@"Globals"] == NSOrderedSame)
	  g_LoadingGlobals = true;
	else {
	  g_LoadingGlobals = false;

	  fmt = new CSVExamineFormat([val UTF8String]);
	  formatList.push_back(fmt);
	}
      }
    }

    // Handle the other configuration lines.
    if ((match = [generalPat firstMatchInString:line options:0 range:range])) {
      if (match.numberOfRanges > 1) {
	name = getAndTrimMatch(line, [match rangeAtIndex:1]);
	value = getAndTrimMatch(line, [match rangeAtIndex:2]);

	err = (g_LoadingGlobals) ?
	  assignAttributeValue([name UTF8String], [value UTF8String], NULL) :
	  assignAttributeValue([name UTF8String], [value UTF8String], fmt);

	if (err != NULL)
	  //
	  // Append the error message with a line number. Syntax error messages pop up once the event loop starts.
	  //
	  g_ConfigLoadErrors = (g_LoadingGlobals) ?
	    [g_ConfigLoadErrors stringByAppendingString:[NSString stringWithFormat:@"Line %lu: [Globals]: %@",
								  lineno, err]] :
	    [g_ConfigLoadErrors stringByAppendingString:[NSString stringWithFormat:@"Line %lu: [%s]: %@",
								  lineno, fmt->name.c_str(), err]];
      }
    }
  }

  // Make sure all the tooltipFormat strings are parsed in the formats.
  for (int i = 0; i < formatList.size(); i++)
    formatList[i]->parseTooltipFormat();
}

@interface MyMenu : NSObject
- (void) copyToClipboard:(id)sender;
@end
@implementation MyMenu
- (void)copyToClipboard:(id)sender {
  NSMenuItem *item = (NSMenuItem *) sender;
  id rov = [item representedObject];
  if ([rov isKindOfClass:[NSNumber class]]) {
    if ([rov unsignedIntegerValue] == 0)
      columnToClipboard();
    else
      columnToClipboardAsRow();
  }
}
@end

static void getPluginMenu() {
  NSMenu *mainMenu = [[NSApplication sharedApplication] mainMenu];
  NSMenu *plugins = NULL, *myplugin = NULL;
  NSMenuItem *clipboard = NULL;

  for (NSMenuItem *item in [mainMenu itemArray]) {
    if ([item hasSubmenu] && [[[item submenu] title] isEqualToString:@"Plugins"]) {
      plugins = [item submenu];
      break;
    }
  }

  for (NSMenuItem *item in [plugins itemArray]) {
    if ([item hasSubmenu] && [[[item submenu] title] isEqualToString:@(PLUGIN_NAME)]) {
      g_Globals.plugin = item;
      plugins = [item submenu];
      break;
    }
  }

  for (NSMenuItem *item in [plugins itemArray]) {
    if ([[item title] isEqualToString:@"Copy To Clipboard"]) {
      clipboard = item;
      break;
    }
  }

  // Save the clipboard menu item so it can enabled and disabled, depending on whether column selection is
  // enabled or disabled.
  [[clipboard menu] setAutoenablesItems:NO];
  [clipboard setEnabled:NO];
  g_Globals.clipboard = clipboard;

  NSMenu *clipboardSubmenu = [[NSMenu alloc] initWithTitle:@"Options"];
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"As Column" action:@selector(copyToClipboard:) keyEquivalent:@""];
  [item setTarget:[[MyMenu alloc] init]];
  [item setRepresentedObject:@(0)];
  [clipboardSubmenu addItem:item];

  item = [[NSMenuItem alloc] initWithTitle:@"As Row" action:@selector(copyToClipboard:) keyEquivalent:@""];
  [item setTarget:[[MyMenu alloc] init]];
  [item setRepresentedObject:@(1)];
  [clipboardSubmenu addItem:item];
  [myplugin setSubmenu:clipboardSubmenu forItem:clipboard];
}

// ---------------------------------------------------------------------------
// Plugin exports
// ---------------------------------------------------------------------------

extern "C" NPP_EXPORT void setInfo(NppData data) {
  nppData = data;

  //
  // Get the configuration.
  //
  loadConfig();

  memset(funcItem, 0, sizeof(funcItem));

  strcpy(funcItem[0]._itemName, "Choose Format");
  funcItem[0]._pFunc = formatMenu;

  strcpy(funcItem[1]._itemName, "Copy To Clipboard");
  funcItem[1]._pFunc = columnToClipboard;

  strcpy(funcItem[2]._itemName, "Select Column");
  funcItem[2]._pFunc = toggleSelectColumn;
  funcItem[2]._init2Check = g_Globals.selectColumn;

  strcpy(funcItem[3]._itemName, "Edit Configuration");
  funcItem[3]._pFunc = editConfig;

  funcItem[4]._itemName[0] = '\0';
  funcItem[4]._pFunc = nullptr;

  strcpy(funcItem[5]._itemName, "About...");
  funcItem[5]._pFunc = showAbout;
}

extern "C" NPP_EXPORT const char *getName() {
  return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
  *nbF = NB_FUNC;
  return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
  if (!n) return;

  NppHandle h = getCurrentScintilla();
  NSUInteger bufferID = nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTBUFFERID, 0, 0);
  void *activeDoc = (void *) sci(h, SCI_GETDOCPOINTER, 0, 0);
  int view = -1;

  nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t) &view);

  switch (n->nmhdr.code) {
  case NPPN_READY:
    // Locate the plugin menu and save it to g_Globals.
    getPluginMenu();

    // Generate the global lists of delimiters and enclosers. Used for auto-detecting CSV format.
    g_Globals.makeLists();

    // Set directionality to LTR. This seems to fix the indicator highlighting disconnect
    // in rows that have a mix of LTR and RTL text.
    sci(h, SCI_SETBIDIRECTIONAL, SC_BIDIRECTIONAL_L2R, 0);

    // Set the mouse dwell time to 1/2 second.
    sci(h, SCI_SETMOUSEDWELLTIME, 500);

    // Show any syntax errors discovered when loading the config file.
    if (![g_ConfigLoadErrors isEqualToString:@""])
      showAlert(@"Configuration Syntax Errors", g_ConfigLoadErrors);

    // Check if the buffer filename is a *.csv. If it is, parse a few lines to determine which format it uses.
    handleBufferChange(h, bufferID, view);

    // Install the NSEvent monitor that intercepts MouseLeftButtonUp if the initial configuration requests it.
    if (g_CurrentBuffer != NULL && g_CurrentBuffer->selectColumn)
      addButtonEventMonitor();

    break;
  case NPPN_SHUTDOWN:
    // Remove the NSEvent monitor that intercepts MouseLeftButtonUp if it hasn't already been removed.
    removeButtonEventMonitor();

    // Disable the mouse dwell notifications.
    sci(h, SCI_SETMOUSEDWELLTIME, SC_TIME_FOREVER);

    //
    // Free up the path to the config file.
    //
    if (g_configPath != nil)
      free(g_configPath);

    break;
  case SCN_DWELLSTART:
    // Show tooltip with the info requested in the tooltip config string.
    handleTooltip(n->position);
    break;
  case SCN_DWELLEND:
    // Cancel any calltips if the mouse moves.
    sci(h, SCI_CALLTIPCANCEL);
    break;
  case SCN_UPDATEUI:
    break;
  case NPPN_BUFFERACTIVATED:
    // Reset the dwell time for tooltips in the new view.
    sci(h, SCI_SETMOUSEDWELLTIME, 500);

    handleBufferChange(h, bufferID, view);
    if (g_CurrentBuffer == NULL)
      removeButtonEventMonitor();
    else if (g_ButtonEventMonitor == nil && g_CurrentBuffer->selectColumn)
      addButtonEventMonitor();
    break;
  }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t /*msg*/, uintptr_t /*wParam*/, intptr_t /*lParam*/) {
    // No inter-plugin message handling.
    return 1;
}
