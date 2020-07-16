//
//  ORCoreFunctionCall.m
//  OCRunner
//
//  Created by Jiang on 2020/7/9.
//  Copyright © 2020 SilverFruity. All rights reserved.
//

#import "ORCoreFunctionCall.h"
#import <Foundation/Foundation.h>
#import "MFValue.h"
#import "ORStructDeclare.h"
#import "ORHandleTypeEncode.h"
#import "ptrauth.h"
#import "ORCoreFunction.h"
NSUInteger floatPointFlagsWithTypeEncode(const char * typeEncode){
    NSUInteger fieldCount = totalFieldCountWithTypeEncode(typeEncode);;
    if (fieldCount <= 4) {
        const char *fieldEncode;
        if (isStructWithTypeEncode(typeEncode)) {
             fieldEncode = detectStructMemeryLayoutEncodeCode(typeEncode).UTF8String;
        }else{
             fieldEncode = typeEncode;
        }
        NSUInteger offset = 0;
        switch (*fieldEncode) {
            case 'f':
                offset = 2;
                break;
            case 'd':
                offset = 3;
                break;
            default:
                break;
        }
        if (fieldEncode == typeEncode && offset == 0) {
            return 0;
        }
        //iOS没有LONGDOUBLE
        //Note that FFI_TYPE_FLOAT == 2, _DOUBLE == 3, _LONGDOUBLE == 4
        //#define AARCH64_RET_S4        8
        //#define AARCH64_RET_D4        12
        return offset * 4 + (4 - fieldCount);
    }
    return 0;
    
}
NSUInteger resultFlagsForTypeEncode(const char * retTypeEncode, char **argTypeEncodes, int narg){
    NSUInteger flag = 0;
    switch (*retTypeEncode) {
        case ':':
        case '*':
        case '#':
        case '^':
        case '@': flag = AARCH64_RET_INT64; break;
        case 'v': flag = AARCH64_RET_VOID; break;
        case 'C': flag = AARCH64_RET_UINT8; break;
        case 'S': flag = AARCH64_RET_UINT16; break;
        case 'I': flag = AARCH64_RET_UINT32; break;
        case 'L': flag = AARCH64_RET_INT64; break;
        case 'Q': flag = AARCH64_RET_INT64; break;
        case 'B': flag = AARCH64_RET_UINT8; break;
        case 'c': flag = AARCH64_RET_SINT8; break;
        case 's': flag = AARCH64_RET_SINT16; break;
        case 'i': flag = AARCH64_RET_SINT32; break;
        case 'l': flag = AARCH64_RET_SINT32; break;
        case 'q': flag = AARCH64_RET_INT64; break;
        case 'f':
        case 'd':
        case '{':{
            flag = floatPointFlagsWithTypeEncode(retTypeEncode);
            NSUInteger s = sizeOfTypeEncode(retTypeEncode);
            if (flag == 0) {
                if (s > 16)
                    flag = AARCH64_RET_VOID | AARCH64_RET_IN_MEM;
                else if (s == 16)
                    flag = AARCH64_RET_INT128;
                else if (s == 8)
                    flag = AARCH64_RET_INT64;
                else
                    flag = AARCH64_RET_INT128 | AARCH64_RET_NEED_COPY;
            }
            break;
        }
        default:
            break;
    }
    for (int i = 0; i < narg; i++) {
        if (isHFAStructWithTypeEncode(argTypeEncodes[i]) || isFloatWithTypeEncode(argTypeEncodes[i])) {
            flag |= AARCH64_FLAG_ARG_V; break;
        }
    }
    return flag;
}
void prepareForStackSize(MFValue *arg, CallRegisterState *state){
    if (arg.isInteger || arg.isPointer || arg.isObject) {
        if (state->NGRN < N_G_ARG_REG) {
            state->NGRN++;
            return;
        }
        state->NGRN = N_G_ARG_REG;
        state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
    }else if (arg.isFloat) {
        if (state->NSRN < N_V_ARG_REG) {
            state->NSRN++;
            return;
        }
        state->NSRN = N_V_ARG_REG;
        state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
        // Composite Types
        // aggregate: struct and array
    }else if (arg.isStruct) {
        if (arg.isHFAStruct) {
            if (arg.structLayoutFieldCount > 4) {
                MFValue *copied = [MFValue valueWithPointer:arg.pointer];
                prepareForStackSize(copied, state);
                return;
            }
            NSUInteger argCount = arg.structLayoutFieldCount;
            if (state->NSRN + argCount <= N_V_ARG_REG) {
                //set args to float register
                state->NSRN += argCount;
                return;
            }
            state->NSRN = N_V_ARG_REG;
            state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
        }else if (arg.memerySize > 16){
            MFValue *copied = [MFValue valueWithPointer:arg.pointer];
            prepareForStackSize(copied, state);
        }else{
            NSUInteger memsize = arg.memerySize;
            NSUInteger needGRN = (memsize + 7) / OR_ALIGNMENT;
            if (8 - state->NGRN >= needGRN) {
                //set args to general register
                state->NGRN += needGRN;
                return;
            }
            state->NGRN = N_V_ARG_REG;
            state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
        }
    }
}

void structStoeInRegister(BOOL isHFA, MFValue *aggregate, CallContext ctx){
    [aggregate enumerateStructFieldsUsingBlock:^(MFValue * _Nonnull field, NSUInteger idx, BOOL *stop) {
        if (field.isStruct) {
            structStoeInRegister(isHFA, field, ctx);
            return;
        }
        CallRegisterState *state = ctx.state;
        void *pointer = field.pointer;
        if (isHFA) {
            memcpy((char *)ctx.floatRegister + state->NSRN * 16, pointer, field.memerySize);
            state->NSRN++;
        }else{
            ctx.generalRegister[state->NGRN] = *(void **)pointer;
            state->NGRN++;
        }
    }];
}
void flatMapArgument(MFValue *arg, CallContext ctx){
    CallRegisterState *state = ctx.state;
    if (arg.isInteger || arg.isPointer || arg.isObject) {
        if (state->NGRN < N_G_ARG_REG) {
            void *pointer = arg.pointer;
            ctx.generalRegister[state->NGRN] = *(void **)pointer;
            state->NGRN++;
            return;
        }else{
            state->NGRN = N_G_ARG_REG;
            void *pointer = arg.pointer;
            memcpy(ctx.stackMemeries + state->NSAA, pointer, arg.memerySize);
            state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
            return;
        }
    }else if (arg.isFloat) {
        if (state->NSRN < N_V_ARG_REG) {
            void *pointer = arg.pointer;
            memcpy((char *)ctx.floatRegister + state->NSRN * V_REG_SIZE, pointer, arg.memerySize);
            state->NSRN++;
            return;
        }else{
            state->NSRN = N_V_ARG_REG;
            void *pointer = arg.pointer;
            memcpy(ctx.stackMemeries + state->NSAA, pointer, arg.memerySize);
            state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
            return;
        }
        // Composite Types
        // aggregate: struct and array
    }else if (arg.isStruct) {
        if (arg.isHFAStruct) {
            //FIXME: only in iOS ???
            if (arg.structLayoutFieldCount > 4) {
                MFValue *copied = [MFValue valueWithPointer:arg.pointer];
                flatMapArgument(copied, ctx);
                return;
            }
            NSUInteger argCount = arg.structLayoutFieldCount;
            if (state->NSRN + argCount <= N_V_ARG_REG) {
                //set args to float register
                structStoeInRegister(YES, arg, ctx);
                return;
            }else{
                state->NSRN = N_V_ARG_REG;
                void *pointer = arg.pointer;
                memcpy(ctx.stackMemeries + state->NSAA, pointer, arg.memerySize);
                state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
                return;
            }
        }else if (arg.memerySize > 16){
            MFValue *copied = [MFValue valueWithPointer:arg.pointer];
            flatMapArgument(copied, ctx);
        }else{
            NSUInteger memsize = arg.memerySize;
            NSUInteger needGRN = (memsize + 7) / OR_ALIGNMENT;
            if (8 - state->NGRN >= needGRN) {
                //set args to general register
                structStoeInRegister(NO, arg, ctx);
                return;
            }else{
                state->NGRN = N_V_ARG_REG;
                void *pointer = arg.pointer;
                memcpy(ctx.stackMemeries + state->NSAA, pointer, arg.memerySize);
                state->NSAA += (arg.memerySize + 7) / OR_ALIGNMENT;
                return;
            }
        }
    }
}
extern void ORCoreFunctionCall(void *stack, void *frame, void *fn, void *ret, NSUInteger flag);;
void invoke_functionPointer(void *funptr, NSArray<MFValue *> *argValues, MFValue *returnValue){
    if (funptr == NULL) {
        return;
    }
    NSUInteger flag = 0;
    do {
        if (returnValue.pointerCount > 0) {
            flag = AARCH64_RET_INT64; break;
        }
        switch (returnValue.type) {
            case TypeSEL:
            case TypeClass:
            case TypeObject:
            case TypeBlock:
            case TypeId:
            case TypeUnKnown: flag = AARCH64_RET_INT64; break;
            case TypeVoid:   flag = AARCH64_RET_VOID; break;
            case TypeUChar:  flag = AARCH64_RET_UINT8; break;
            case TypeUShort: flag = AARCH64_RET_UINT16; break;
            case TypeUInt:   flag = AARCH64_RET_UINT32; break;
            case TypeULong:  flag = AARCH64_RET_INT64; break;
            case TypeULongLong: flag = AARCH64_RET_INT64; break;
            case TypeBOOL:   flag = AARCH64_RET_UINT8; break;
            case TypeChar:   flag = AARCH64_RET_SINT8; break;
            case TypeShort:  flag = AARCH64_RET_SINT16; break;
            case TypeInt:    flag = AARCH64_RET_SINT32; break;
            case TypeLong:   flag = AARCH64_RET_SINT32; break;
            case TypeLongLong: flag = AARCH64_RET_INT64; break;
            case TypeFloat:
            case TypeDouble:
            case TypeStruct:{
                flag = floatPointFlagsWithTypeEncode(returnValue.typeEncode);
                NSUInteger s = returnValue.memerySize;
                if (flag == 0) {
                    if (s > 16)
                        flag = AARCH64_RET_VOID | AARCH64_RET_IN_MEM;
                    else if (s == 16)
                        flag = AARCH64_RET_INT128;
                    else if (s == 8)
                        flag = AARCH64_RET_INT64;
                    else
                        flag = AARCH64_RET_INT128 | AARCH64_RET_NEED_COPY;
                }
                break;
            }
            default:
                break;
        }
        for (NSUInteger i = 0 ; i < argValues.count; i++)
            if (argValues[i].isHFAStruct)
                flag |= AARCH64_FLAG_ARG_V; break;
        break;
    }while (0);
    
    NSMutableArray *args = [argValues mutableCopy];
    CallRegisterState prepareState = { 0 , 0 , 0};
    for (MFValue *arg in args) {
        prepareForStackSize(arg, &prepareState);
    }
    NSUInteger stackSize = prepareState.NSAA;
    NSUInteger retSize = 0;
    if (flag & AARCH64_RET_NEED_COPY) {
        retSize = 16;
    }else{
        retSize = returnValue.memerySize;
    }
    char *stack = alloca(CALL_CONTEXT_SIZE + stackSize + 40 + retSize);
    memset(stack, 0, CALL_CONTEXT_SIZE + stackSize + 40 + retSize);
    CallRegisterState state = { 0 , 0 , 0};;
    CallContext context;
    context.state = &state;
    context.floatRegister = (void *)stack;
    context.generalRegister = (char *)context.floatRegister + V_REG_TOTAL_SIZE;
    context.stackMemeries = (char *)context.generalRegister + G_REG_TOTAL_SIZE;
    context.frame = (char *)context.stackMemeries + + stackSize;
    context.retPointer = (char *)context.frame + 40;
    for (MFValue *arg in args) {
        flatMapArgument(arg, context);
    }
    ORCoreFunctionCall(stack, context.frame, funptr, context.retPointer, flag);
    void *pointer = context.retPointer;
    returnValue.pointer = pointer;
}


