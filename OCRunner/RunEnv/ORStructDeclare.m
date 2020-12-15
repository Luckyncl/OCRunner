//
//  MFStructDeclare.m
//  MangoFix
//
//  Created by jerry.yong on 2017/11/16.
//  Copyright © 2017年 yongpengliang. All rights reserved.
//

#import "ORStructDeclare.h"
#import "ORHandleTypeEncode.h"

@implementation ORStructDeclare
+ (instancetype)structDecalre:(const char *)encode keys:(NSArray *)keys{
    return [[self alloc] initWithTypeEncode:encode keys:keys];
}
- (instancetype)initWithTypeEncode:(const char *)typeEncoding keys:(NSArray<NSString *> *)keys{
    self = [super init];
    char *encode = malloc(sizeof(char) * (strlen(typeEncoding) + 1) );
    strcpy(encode, typeEncoding);
    self.typeEncoding = encode;
    NSMutableArray *results = startStructDetect(typeEncoding);
    self.name = results[0];
    self.keys = keys;
    [results removeObjectAtIndex:0];
    [self initialWithFieldTypeEncodes:[results copy]];
    return self;
}
- (void)initialWithFieldTypeEncodes:(NSArray *)fieldEncodes{
    NSMutableDictionary *keySizes = [NSMutableDictionary dictionary];
    NSMutableDictionary *keyTyeps = [NSMutableDictionary dictionary];
    NSCAssert(self.keys.count == fieldEncodes.count, @"");
    [fieldEncodes enumerateObjectsUsingBlock:^(NSString *elementEncode, NSUInteger idx, BOOL * _Nonnull stop) {
        NSUInteger size;
        NSGetSizeAndAlignment(elementEncode.UTF8String, &size, NULL);
        keySizes[self.keys[idx]] = @(size);
        keyTyeps[self.keys[idx]] = elementEncode;
    }];
    self.keySizes = keySizes;
    self.keyTypeEncodes = keyTyeps;
    // 内存对齐
    // 第一个变量的偏移量为0，其余变量的偏移量需要是变量内存大小的的整数倍
    NSMutableDictionary <NSString *,NSNumber *>*keyOffsets = [NSMutableDictionary dictionary];
    for (int i = 0; i < self.keys.count; i++) {
        if (i == 0) {
            keyOffsets[self.keys[i]] = @(0);
            continue;
        }
        NSString *lastKey = self.keys[i - 1];
        NSUInteger lastSize = self.keySizes[lastKey].unsignedIntValue;
        NSUInteger lastOffset = keyOffsets[lastKey].unsignedIntValue;
        NSUInteger offset = lastOffset + lastSize;
        NSUInteger size = self.keySizes[self.keys[i]].unsignedIntegerValue;
        size = MIN(size, 8); // 在参数对齐数和默认对齐数8取小
        if (offset % size != 0) {
            offset = ((offset + size - 1) / size) * size;
        }
        keyOffsets[self.keys[i]] = @(offset);
    }
    self.keyOffsets = keyOffsets;
}
- (void)dealloc
{
    if (self.typeEncoding != NULL) {
        void *encode = (void *)self.typeEncoding;
        free(encode);
    }
}
@end
@implementation ORUnionDeclare
+ (instancetype)unionDecalre:(const char *)encode keys:(NSArray *)keys{
    return [[self alloc] initWithTypeEncode:encode keys:keys];
}
- (instancetype)initWithTypeEncode:(const char *)typeEncoding keys:(NSArray<NSString *> *)keys{
    self = [super init];
    char *encode = malloc(sizeof(char) * (strlen(typeEncoding) + 1) );
    strcpy(encode, typeEncoding);
    self.typeEncoding = encode;
    NSMutableArray *results = startUnionDetect(typeEncoding);
    self.name = results[0];
    self.keys = keys;
    [results removeObjectAtIndex:0];
    NSMutableDictionary *keyTyeps = [NSMutableDictionary dictionary];
    NSCAssert(self.keys.count == results.count, @"");
    [results enumerateObjectsUsingBlock:^(NSString *elementEncode, NSUInteger idx, BOOL * _Nonnull stop) {
        keyTyeps[self.keys[idx]] = elementEncode;
    }];
    self.keyTypeEncodes = keyTyeps;
    return self;
}
- (void)dealloc
{
    if (self.typeEncoding != NULL) {
        void *encode = (void *)self.typeEncoding;
        free(encode);
    }
}
@end

@implementation ORStructDeclareTable{
    NSMutableDictionary<NSString *, ORStructDeclare *> *_cache;
}

- (instancetype)init{
    if (self = [super init]) {
        _cache = [NSMutableDictionary dictionary];
    }
    return self;
}
+ (instancetype)shareInstance{
    static id st_instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        st_instance = [[ORStructDeclareTable alloc] init];
    });
    return st_instance;
}
- (void)addAlias:(NSString *)alias forTypeName:(NSString *)name{
    id value = [_cache objectForKey:name];
    if (value) {
        _cache[name] = value;
    }
}
- (void)addAlias:(NSString *)alias forStructTypeEncode:(const char *)typeEncode{
    NSString *structName = startStructNameDetect(typeEncode);
    [self addAlias:alias forTypeName:structName];
}
- (void)addStructDeclare:(ORStructDeclare *)structDeclare{
    if (structDeclare && structDeclare.name) {
        _cache[structDeclare.name] = structDeclare;
    }
}

- (ORStructDeclare *)getStructDeclareWithName:(NSString *)name{
    return _cache[name];
}
@end


@implementation ORTypeVarPair (Struct)
- (ORStructDeclare *)strcutDeclare{
    NSCAssert(self.type.type == TypeStruct, @"must be TypeStruct");
    return [[ORTypeSymbolTable shareInstance] symbolItemForTypeName:self.type.name].declare;
}
@end

#import "ORTypeVarPair+TypeEncode.h"
@implementation ORSymbolItem
- (NSString *)description{
    return [NSString stringWithFormat:@"ORSymbolItem:{ encode:%@ type: %@ }",self.typeEncode,self.typeName];
}
- (BOOL)isStruct{
    return *self.typeEncode.UTF8String == OCTypeStruct;
}
- (BOOL)isUnion{
    return *self.typeEncode.UTF8String == OCTypeUnion;
}
- (BOOL)isCArray{
    return *self.typeEncode.UTF8String == OCTypeArray;
}
@end
@implementation ORTypeSymbolTable{
    NSMutableDictionary<NSString *, ORSymbolItem *> *_table;
}

- (instancetype)init{
    if (self = [super init]) {
        _table = [NSMutableDictionary dictionary];
    }
    return self;
}
+ (instancetype)shareInstance{
    static id st_instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        st_instance = [[ORTypeSymbolTable alloc] init];
    });
    return st_instance;
}
- (ORSymbolItem *)addTypePair:(ORTypeVarPair *)typePair{
    NSCAssert(typePair.var.varname != nil, @"");
    return [self addTypePair:typePair forAlias:typePair.var.varname];
}
- (ORSymbolItem *)addTypePair:(ORTypeVarPair *)typePair forAlias:(NSString *)alias{
    ORSymbolItem *item = [self symbolItemForTypeName:alias];
    if (item == nil) {
        item = [[ORSymbolItem alloc] init];
        item.typeEncode = [NSString stringWithUTF8String:typePair.typeEncode];
        item.typeName = typePair.type.name;
    }
    [self addSybolItem:item forAlias:alias];
    return item;
}
- (ORSymbolItem *)addUnion:(ORUnionDeclare *)declare{
    return [self addUnion:declare forAlias:declare.name];
}
- (ORSymbolItem *)addStruct:(ORStructDeclare *)declare{
    return [self addStruct:declare forAlias:declare.name];
}
- (ORSymbolItem *)addStruct:(ORStructDeclare *)declare forAlias:(NSString *)alias{
    ORSymbolItem *item = [self symbolItemForTypeName:alias];
    if (item == nil) {
        item = [[ORSymbolItem alloc] init];
        item.typeEncode = [NSString stringWithUTF8String:declare.typeEncoding];
        item.typeName = declare.name;
    }
    item.declare = declare;
    [self addSybolItem:item forAlias:alias];
    return item;
}
- (ORSymbolItem *)addUnion:(ORUnionDeclare *)declare forAlias:(NSString *)alias{
    ORSymbolItem *item = [self symbolItemForTypeName:alias];
    if (item == nil) {
        item = [[ORSymbolItem alloc] init];
        item.typeEncode = [NSString stringWithUTF8String:declare.typeEncoding];
        item.typeName = declare.name;
    }
    item.declare = declare;
    [self addSybolItem:item forAlias:alias];
    return item;
}
- (void)addSybolItem:(ORSymbolItem *)item forAlias:(NSString *)alias{
    NSAssert(alias != nil, @"");
    if (alias.length == 0) {
        return;
    }
    _table[alias] = item;
}
- (ORSymbolItem *)symbolItemForTypeName:(NSString *)typeName{
    ORSymbolItem *item = _table[typeName];
    return item;
}
@end
