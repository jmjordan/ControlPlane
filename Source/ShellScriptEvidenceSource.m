//
//  ShellScriptEvidenceSource.m
//  ControlPlane
//
//  Created by Dustin Rue 8/5/2011.
//  Updated 1/15/2012
//
//  This evidence source allows the end user to create
//  their own custom evidence source using an external program,
//  or script.  Anything can be used so long as it returns 0
//  for success and 1 for failure.

#import "ShellScriptEvidenceSource.h"
#import "DSLogger.h"
#import "NSTimer+Invalidation.h"
#import "NSString+ShellScriptHelper.h"

@interface ShellScriptEvidenceSource (Private)

- (void) fileBrowseSheetFinished:(NSWindow*)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void) scriptTimer:(NSTimer *)theTimer;
- (void) runScript:(NSString *)scriptName;
- (void) doUpdate:(NSTimer *)theTimer;
- (void) stopAllTasks;
- (void) setDefaultValues;

@end


@implementation ShellScriptEvidenceSource
@synthesize currentFileName;
@synthesize scriptInterval;


- (id)init {
    self = [super initWithNibNamed:@"ShellScriptRule"];
    if (!self)
        return nil;
    
    running = NO;
	ruleUpdateTimer = nil;
    [self setDefaultValues];
	
	return self;
}


- (NSString *) description {
    return NSLocalizedString(@"Create rules based on your own shell script based evidence source.  Shell scripts must exit with status code 0 for success or 1 for failure.", @"");
}

- (void) setDefaultValues {
    [self setScriptInterval:@"10"];
    [self setCurrentFileName:NSLocalizedString(@"Please browse for a shell script...",@"")];
}


- (void)dealloc {
	[super dealloc];
}

- (void)start {
    // will be used to store a timer object for each
    // rule that has been configured
    taskTimers = [[NSMutableDictionary alloc] init];
    myTasks    = [[NSArray alloc] init];
    

    // do an update immediately
    [self getRuleList];
    
    // setDataCollected to true now so that 
    // rules can be configured immediately
    [self setDataCollected:true];
    running = YES;
}

- (void)stop {        
    [self stopAllTasks];
    [myTasks         release];
    [taskTimers      release];

    [self setDataCollected: NO];
    running = NO;
}

- (void)stopAllTasks {
    for (NSDictionary *task in myTasks) {
#if DEBUG_MODE
        DSLog(@"disabling timer for task %@",[task valueForKey:@"parameter"]);
#endif
        NSTimer *tmp = [taskTimers objectForKey:[task valueForKey:@"parameter"]];
		if (tmp && [tmp isValid])
			[tmp invalidate];
    }
}


- (void)getRuleList {
    
#if DEBUG_MODE
    DSLog(@"doing update");
#endif
    
    
    // create an array of the currently configured rules
    NSArray *tmpRules = [[NSArray alloc] initWithArray:[self myRules]];
    
    
    // compare the tasks ControlPlane knows about to the currently configured rules
    if ([myTasks isEqualToArray:tmpRules]) {
        [tmpRules release];

        return;
    }
    else {
#if DEBUG_MODE
        DSLog(@"rules list has changed");
#endif
        [self stopAllTasks];
        myTasks = [[tmpRules copy] retain];
        [tmpRules release];
    }

    
#if DEBUG_MODE
    DSLog(@"my rules returned %@", myTasks);
#endif
    
    
    // loop through all of the tasks and start them on a timer
    // based on how they were configured by the user, but the timer must
    // be >= 5 seconds
    for (NSDictionary *currentTask in myTasks) {
        NSTimer *tmp;
        
#if DEBUG_MODE
        DSLog(@"going to perform %@ every %@ seconds", [currentTask valueForKey:@"parameter"], [currentTask valueForKey:@"scriptInterval"]);
#endif

        NSTimeInterval interval = [[currentTask valueForKey:@"scriptInterval"] doubleValue];

        // ensure interval is at least 5 seconds
        // and isn't null.  Right now this could only happen if the user
        // manually edited the configuration file because the interface
        // will never set it lower than 5
        if (interval < 5) {
            // refusing to do an interval of less than 5 seconds
            continue;
        }
        tmp = [NSTimer scheduledTimerWithTimeInterval:interval
                                               target:self
                                             selector:@selector(scriptTimer:)
                                             userInfo:[currentTask valueForKey:@"parameter"]
                                              repeats:YES];
        [taskTimers setObject:tmp forKey:[currentTask valueForKey:@"parameter"]];
        [self runScript:[currentTask valueForKey:@"parameter"]];
    }

    if ([scriptResults count] > 0) {
        [scriptResults release];
    }
    

    scriptResults = [[NSMutableDictionary alloc] initWithCapacity:[myTasks count]];
    
    // set that none of the tasks have a success result
    for (NSDictionary * aTask in myTasks) {
        [scriptResults setValue: [NSNumber numberWithBool: NO] forKey:[aTask valueForKey:@"parameter"]];
    }
}

- (void) scriptTimer:(NSTimer *)theTimer {
    [self runScript:(NSString *)[theTimer userInfo]];
}

- (void) runScript:(NSString *)scriptName {

    NSFileHandle *devnull = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];
    
    NSMutableArray *args = [[NSMutableArray alloc] initWithCapacity:1];
    
	[args addObject:scriptName];
    
#if DEBUG_MODE
    DSLog(@"attempting to run %@", [args objectAtIndex:0]);
#endif
    
    NSTask *task = [[NSTask alloc] init];
    
    [task setArguments:args];
    
    NSString *interpreter = nil;
    
    NSMutableArray *shebangArgs = [scriptName interpreterFromFile];
	if (shebangArgs && [shebangArgs count] > 0) {
		// get interpreter
		interpreter = [shebangArgs objectAtIndex: 0];
		[shebangArgs removeObjectAtIndex: 0];
		
		// and it's parameters
		if (shebangArgs.count > 0) {
			[shebangArgs addObjectsFromArray: args];
            [args removeAllObjects];
            [args addObjectsFromArray:shebangArgs];
		}

		
	}
    
    // backup routine to try using the file extension if it exists
    if ([interpreter isEqualToString: @""]) {
		interpreter = [scriptName interpreterFromExtension];
	}
    
    // ensure that the discovered interpreter is valid and executable
    if ([interpreter isEqualToString: @""] || ![NSFileManager.defaultManager isExecutableFileAtPath:interpreter]) {
        // can't determine how to run the script
        DSLog(@"Failed to execute '%@' because ControlPlane cannot determine how to do so.  Please use '#!/bin/bash' or similar in the script or rename the script with a file extension", scriptName);
        
        [task release];
        [args release];
        // we bail
        return;
        
    }
    
    [task setLaunchPath:interpreter];
    [task setCurrentDirectoryPath:NSHomeDirectory()];
    
    // set error, input and output to dev null or NSTask will never
    // notice that the script has ended.  
    [task setStandardError:devnull];
    [task setStandardInput:devnull];
    [task setStandardOutput:devnull];
    
    [task launch];
    
    [task waitUntilExit];
    
#if DEBUG_MODE
    DSLog(@"task ended");
#endif
    
    if ([task terminationStatus] != 0) {
#if DEBUG_MODE
        DSLog(@"script reported fail");
#endif
        [scriptResults setObject: [NSNumber numberWithBool: NO] forKey:[args objectAtIndex:0]];
        [task release];
        [args release];
    }
    else {
#if DEBUG_MODE
        DSLog(@"script reported success");
#endif
        [scriptResults setValue: [NSNumber numberWithBool: YES] forKey:[args objectAtIndex:0]];
        [task release];
        [args release];
    }
}

- (NSString *)name {
	return @"ShellScript";
}

- (BOOL)doesRuleMatch:(NSDictionary *)rule {
    return [[scriptResults valueForKey:[rule valueForKey:@"parameter"]] boolValue];
}

- (NSMutableDictionary *)readFromPanel {
    NSMutableDictionary *dict = [super readFromPanel];
	
	// store values

    // for now, silently limit the minimum value to 5 seconds
    if ([scriptInterval doubleValue] < 5) {
        [dict setValue: @"5"  forKey: @"scriptInterval"];
    }
    else {
        [dict setValue: scriptInterval  forKey: @"scriptInterval"];
    }
	[dict setValue: currentFileName forKey: @"parameter"];
    [dict setValue: currentFileName forKey: @"description"];

    [dict setValue: @"ShellScript"  forKey: @"type"];
	
	return dict;
}

- (void)writeToPanel:(NSDictionary *)dict usingType:(NSString *)type {
	[super writeToPanel: dict usingType: type];
	
    
	// show values
    if ([dict objectForKey:@"parameter"]) {
        [self setCurrentFileName:[dict objectForKey:@"parameter"]];
        [self setScriptInterval:[dict objectForKey:@"scriptInterval"]];
    }
    else {
        [self setDefaultValues];
    }

   
}


- (void)clearCollectedData {
    
}

- (IBAction) browseForScript:(id) sendor {
    NSOpenPanel *fileBrowser = [NSOpenPanel openPanel];
    
    [fileBrowser setCanChooseFiles:YES];
    [fileBrowser setCanChooseDirectories:NO];
    
    if ([fileBrowser runModal] == NSOKButton) {
        [self setCurrentFileName:[[fileBrowser URL] path]];
    }
        
 
}

// being asked if we are running, this usually means this source
// has just been enabled or the rules have changed
// If this evidence source is running it wants to immediately
// fetch rules so the tasks can be started
- (BOOL)isRunning {
    if (running) 
        [self getRuleList];
	return running;
}

- (NSString *) friendlyName {
    return NSLocalizedString(@"Shell Script", @"");
}

@end
