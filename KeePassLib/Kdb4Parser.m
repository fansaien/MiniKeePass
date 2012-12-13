/*
 * Copyright 2011 Jason Rush and John Flanagan. All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "Kdb4Parser.h"
#import "Kdb4Node.h"
#import "DDXML.h"
#import "DDXMLElementAdditions.h"
#import "DDXMLDocument+MKPAdditions.h"
#import "DDXMLElement+MKPAdditions.h"
#import "Base64.h"

#define FIELD_TITLE     @"Title"
#define FIELD_USER_NAME @"UserName"
#define FIELD_PASSWORD  @"Password"
#define FIELD_URL       @"URL"
#define FIELD_NOTES     @"Notes"

@interface Kdb4Parser (PrivateMethods)
- (void)decodeProtected:(DDXMLElement *)root;
- (void)parseMeta:(DDXMLElement *)root;
- (Binary *)parseBinary:(DDXMLElement *)root;
- (Kdb4Group *)parseGroup:(DDXMLElement *)root;
- (Kdb4Entry *)parseEntry:(DDXMLElement *)root;
- (BinaryRef *)parseBinaryRef:(DDXMLElement *)root;
- (AutoType *)parseAutoType:(DDXMLElement *)root;
- (UUID *)parseUuidString:(NSString *)uuidString;
@end

@implementation Kdb4Parser

- (id)initWithRandomStream:(RandomStream *)cryptoRandomStream {
    self = [super init];
    if (self) {
        randomStream = [cryptoRandomStream retain];

        dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        dateFormatter.dateFormat = @"yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'";
    }
    return self;
}

- (void)dealloc {
    [randomStream release];
    [dateFormatter release];
    [super dealloc];
}

int	readCallback(void *context, char *buffer, int len) {
    InputStream *inputStream = (InputStream*)context;
    return [inputStream read:buffer length:len];
}

int closeCallback(void *context) {
    return 0;
}

- (Kdb4Tree *)parse:(InputStream *)inputStream {
    DDXMLDocument *document = [[DDXMLDocument alloc] initWithReadIO:readCallback closeIO:closeCallback context:inputStream options:0 error:nil];
    if (document == nil) {
        @throw [NSException exceptionWithName:@"ParseError" reason:@"Failed to parse database" userInfo:nil];
    }

    NSLog(@"\n%@", document);

    // Get the root document element
    DDXMLElement *rootElement = [document rootElement];

    // Decode all the protected entries
    [self decodeProtected:rootElement];

    Kdb4Tree *tree = [[Kdb4Tree alloc] init];

    DDXMLElement *meta = [rootElement elementForName:@"Meta"];
    if (meta != nil) {
        [self parseMeta:meta tree:tree];
    }

    DDXMLElement *root = [rootElement elementForName:@"Root"];
    if (root == nil) {
        [document release];
        @throw [NSException exceptionWithName:@"ParseError" reason:@"Failed to parse database" userInfo:nil];
    }

    DDXMLElement *element = [root elementForName:@"Group"];
    if (element == nil) {
        [document release];
        @throw [NSException exceptionWithName:@"ParseError" reason:@"Failed to parse database" userInfo:nil];
    }

    tree.root = [self parseGroup:element];

    [document release];

    return [tree autorelease];
}

- (void)decodeProtected:(DDXMLElement *)root {
    DDXMLNode *protectedAttribute = [root attributeForName:@"Protected"];
    if ([[protectedAttribute stringValue] isEqual:@"True"]) {
        NSString *str = [root stringValue];

        // Base64 decode the string
        NSMutableData *data = [Base64 decode:[str dataUsingEncoding:NSASCIIStringEncoding]];

        // Unprotect the password
        [randomStream xor:data];

        NSString *unprotected = [[NSString alloc] initWithBytes:data.bytes length:data.length encoding:NSUTF8StringEncoding];
        [root setStringValue:unprotected];
        [unprotected release];
    }

    for (DDXMLNode *node in [root children]) {
        if ([node kind] == DDXMLElementKind) {
            [self decodeProtected:(DDXMLElement*)node];
        }
    }
}

- (void)parseMeta:(DDXMLElement *)root tree:(Kdb4Tree *)tree {
    tree.generator = [[root elementForName:@"Generator"] stringValue];
    tree.databaseName = [[root elementForName:@"DatabaseName"] stringValue];
    tree.databaseNameChanged = [dateFormatter dateFromString:[[root elementForName:@"DatabaseNameChanged"] stringValue]];
    tree.databaseDescription = [[root elementForName:@"DatabaseDescription"] stringValue];
    tree.databaseDescriptionChanged = [dateFormatter dateFromString:[[root elementForName:@"DatabaseDescriptionChanged"] stringValue]];
    tree.defaultUserName = [[root elementForName:@"DefaultUserName"] stringValue];
    tree.defaultUserNameChanged = [dateFormatter dateFromString:[[root elementForName:@"DefaultUserNameChanged"] stringValue]];
    tree.maintenanceHistoryDays = [[[root elementForName:@"MaintenanceHistoryDays"] stringValue] integerValue];
    tree.color = [[root elementForName:@"Color"] stringValue];
    tree.masterKeyChanged = [dateFormatter dateFromString:[[root elementForName:@"MasterKeyChanged"] stringValue]];
    tree.masterKeyChangeRec = [[[root elementForName:@"MasterKeyChangeRec"] stringValue] integerValue];
    tree.masterKeyChangeForce = [[[root elementForName:@"MasterKeyChangeForce"] stringValue] integerValue];

    DDXMLElement *element = [root elementForName:@"MemoryProtection"];
    tree.protectTitle = [[[element elementForName:@"ProtectTitle"] stringValue] boolValue];
    tree.protectUserName = [[[element elementForName:@"ProtectUserName"] stringValue] boolValue];
    tree.protectPassword = [[[element elementForName:@"ProtectPassword"] stringValue] boolValue];
    tree.protectUrl = [[[element elementForName:@"ProtectURL"] stringValue] boolValue];
    tree.protectNotes = [[[element elementForName:@"ProtectNotes"] stringValue] boolValue];

    tree.recycleBinEnabled = [[[root elementForName:@"RecycleBinEnabled"] stringValue] boolValue];
    tree.recycleBinUuid = [self parseUuidString:[[root elementForName:@"RecycleBinUUID"] stringValue]];
    tree.recycleBinChanged = [dateFormatter dateFromString:[[root elementForName:@"RecycleBinChanged"] stringValue]];
    tree.entryTemplatesGroup = [self parseUuidString:[[root elementForName:@"EntryTemplatesGroup"] stringValue]];
    tree.entryTemplatesGroupChanged = [dateFormatter dateFromString:[[root elementForName:@"EntryTemplatesGroupChanged"] stringValue]];
    tree.historyMaxItems = [[[root elementForName:@"HistoryMaxItems"] stringValue] integerValue];
    tree.historyMaxSize = [[[root elementForName:@"HistoryMaxSize"] stringValue] integerValue];
    tree.lastSelectedGroup = [self parseUuidString:[[root elementForName:@"LastSelectedGroup"] stringValue]];
    tree.lastTopVisibleGroup = [self parseUuidString:[[root elementForName:@"LastTopVisibleGroup"] stringValue]];

    DDXMLElement *binariesElement = [root elementForName:@"Binaries"];
    for (DDXMLElement *element in [binariesElement elementsForName:@"Binary"]) {
        [tree.binaries addObject:[self parseBinary:element]];
    }

    // FIXME CustomData
}

- (Binary *)parseBinary:(DDXMLElement *)root {
    Binary *binary = [[Binary alloc] init];

    binary.binaryId = [[[root attributeForName:@"ID"] stringValue] integerValue];
    binary.compressed = [[[root attributeForName:@"Compressed"] stringValue] boolValue];
    binary.data = [root stringValue];

    return binary;
}

- (Kdb4Group *)parseGroup:(DDXMLElement *)root {
    Kdb4Group *group = [[[Kdb4Group alloc] init] autorelease];

    group.uuid = [self parseUuidString:[[root elementForName:@"UUID"] stringValue]];
    group.name = [[root elementForName:@"Name"] stringValue];
    group.notes = [[root elementForName:@"Notes"] stringValue];
    group.image = [[[root elementForName:@"IconID"] stringValue] integerValue];

    DDXMLElement *timesElement = [root elementForName:@"Times"];
    group.lastModificationTime = [dateFormatter dateFromString:[[timesElement elementForName:@"LastModificationTime"] stringValue]];
    group.creationTime = [dateFormatter dateFromString:[[timesElement elementForName:@"CreationTime"] stringValue]];
    group.lastAccessTime = [dateFormatter dateFromString:[[timesElement elementForName:@"LastAccessTime"] stringValue]];
    group.expiryTime = [dateFormatter dateFromString:[[timesElement elementForName:@"ExpiryTime"] stringValue]];
    group.expires = [[[timesElement elementForName:@"Expires"] stringValue] boolValue];
    group.usageCount = [[[timesElement elementForName:@"UsageCount"] stringValue] integerValue];
    group.locationChanged = [dateFormatter dateFromString:[[timesElement elementForName:@"LocationChanged"] stringValue]];

    group.isExpanded = [[[root elementForName:@"IsExpanded"] stringValue] boolValue];
    group.defaultAutoTypeSequence = [[root elementForName:@"DefaultAutoTypeSequence"] stringValue];
    group.EnableAutoType = [[root elementForName:@"EnableAutoType"] stringValue];
    group.EnableSearching = [[root elementForName:@"EnableSearching"] stringValue];
    group.LastTopVisibleEntry = [self parseUuidString:[[root elementForName:@"LastTopVisibleEntry"] stringValue]];

    for (DDXMLElement *element in [root elementsForName:@"Entry"]) {
        Kdb4Entry *entry = [self parseEntry:element];
        entry.parent = group;

        [group addEntry:entry];
    }

    for (DDXMLElement *element in [root elementsForName:@"Group"]) {
        Kdb4Group *subGroup = [self parseGroup:element];
        subGroup.parent = group;

        [group addGroup:subGroup];
    }

    return group;
}

- (Kdb4Entry *)parseEntry:(DDXMLElement *)root {
    Kdb4Entry *entry = [[[Kdb4Entry alloc] init] autorelease];

    entry.uuid = [self parseUuidString:[[root elementForName:@"UUID"] stringValue]];
    entry.image = [[[root elementForName:@"IconID"] stringValue] integerValue];
    entry.foregroundColor = [[root elementForName:@"ForegroundColor"] stringValue];
    entry.backgroundColor = [[root elementForName:@"BackgroundColor"] stringValue];
    entry.overrideUrl = [[root elementForName:@"OverrideURL"] stringValue];
    entry.tags = [[root elementForName:@"Tags"] stringValue];

    DDXMLElement *timesElement = [root elementForName:@"Times"];
    entry.lastModificationTime = [dateFormatter dateFromString:[[timesElement elementForName:@"LastModificationTime"] stringValue]];
    entry.creationTime = [dateFormatter dateFromString:[[timesElement elementForName:@"CreationTime"] stringValue]];
    entry.lastAccessTime = [dateFormatter dateFromString:[[timesElement elementForName:@"LastAccessTime"] stringValue]];
    entry.expiryTime = [dateFormatter dateFromString:[[timesElement elementForName:@"ExpiryTime"] stringValue]];
    entry.expires = [[[timesElement elementForName:@"Expires"] stringValue] boolValue];
    entry.usageCount = [[[timesElement elementForName:@"UsageCount"] stringValue] integerValue];
    entry.locationChanged = [dateFormatter dateFromString:[[timesElement elementForName:@"LocationChanged"] stringValue]];

    for (DDXMLElement *element in [root elementsForName:@"String"]) {
        NSString *key = [[element elementForName:@"Key"] stringValue];

        DDXMLElement *valueElement = [element elementForName:@"Value"];
        NSString *value = [valueElement stringValue];

        if ([key isEqualToString:FIELD_TITLE]) {
            entry.title = value;
        } else if ([key isEqualToString:FIELD_USER_NAME]) {
            entry.username = value;
        } else if ([key isEqualToString:FIELD_PASSWORD]) {
            entry.password = value;
        } else if ([key isEqualToString:FIELD_URL]) {
            entry.url = value;
        } else if ([key isEqualToString:FIELD_NOTES]) {
            entry.notes = value;
        } else {
            StringField *stringField = [[StringField alloc] init];
            stringField.key = key;
            stringField.value = value;
            stringField.protected = [[element attributeForName:@"Protected"] isEqual:@"True"];
            [entry.stringFields addObject:stringField];
        }
    }

    for (DDXMLElement *element in [root elementsForName:@"Binary"]) {
        [entry.binaries addObject:[self parseBinaryRef:element]];
    }

    entry.autoType = [self parseAutoType:[root elementForName:@"AutoType"]];

    return entry;
}

- (BinaryRef *)parseBinaryRef:(DDXMLElement *)root {
    BinaryRef *binaryRef = [[[BinaryRef alloc] init] autorelease];

    binaryRef.key = [[root elementForName:@"Key"] stringValue];
    binaryRef.ref = [[[[root elementForName:@"Value"] attributeForName:@"Ref"] stringValue] integerValue];

    return binaryRef;
}

- (AutoType *)parseAutoType:(DDXMLElement *)root {
    AutoType *autoType = [[[AutoType alloc] init] autorelease];

    autoType.enabled = [[[root elementForName:@"Enabled"] stringValue] boolValue];
    autoType.dataTransferObfuscation = [[[root elementForName:@"DataTransferObfuscation"] stringValue] integerValue];

    for (DDXMLElement *element in [root elementsForName:@"Association"]) {
        Association *association = [[[Association alloc] init] autorelease];

        association.window = [[element elementForName:@"Window"] stringValue];
        association.keystrokeSequence = [[element elementForName:@"KeystrokeSequence"] stringValue];

        [autoType.associations addObject:association];
    }

    return autoType;
}

- (UUID *)parseUuidString:(NSString *)uuidString {
    NSData *data = [Base64 decode:[uuidString dataUsingEncoding:NSUTF8StringEncoding]];
    return [[[UUID alloc] initWithData:data] autorelease];
}

@end
