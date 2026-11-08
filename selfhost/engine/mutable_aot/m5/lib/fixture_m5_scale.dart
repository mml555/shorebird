// MAOT-5 (#69) Task C -- SCALE LADDER.
//
// One program, 512 mutable declarations, every body NON-LEAF (it interpolates,
// so it carries real static calls -- the shape that exposed the STAGE20
// root-enumeration defect).
//
// The population under test is varied with --maot_limit_selected rather than
// by editing the program, so N is the only thing that changes between runs.
// Editing the fixture per point would vary the program and the population at
// once, and the question is specifically about population size.
import 'dart:io' show Platform;

final int input = int.tryParse(Platform.environment['M5_INPUT'] ?? '') ?? 10;

class C0 { @pragma('maot:mutable') String v(int x) => 'C0:${x * 2}'; }
class C1 { @pragma('maot:mutable') String v(int x) => 'C1:${x * 2}'; }
class C2 { @pragma('maot:mutable') String v(int x) => 'C2:${x * 2}'; }
class C3 { @pragma('maot:mutable') String v(int x) => 'C3:${x * 2}'; }
class C4 { @pragma('maot:mutable') String v(int x) => 'C4:${x * 2}'; }
class C5 { @pragma('maot:mutable') String v(int x) => 'C5:${x * 2}'; }
class C6 { @pragma('maot:mutable') String v(int x) => 'C6:${x * 2}'; }
class C7 { @pragma('maot:mutable') String v(int x) => 'C7:${x * 2}'; }
class C8 { @pragma('maot:mutable') String v(int x) => 'C8:${x * 2}'; }
class C9 { @pragma('maot:mutable') String v(int x) => 'C9:${x * 2}'; }
class C10 { @pragma('maot:mutable') String v(int x) => 'C10:${x * 2}'; }
class C11 { @pragma('maot:mutable') String v(int x) => 'C11:${x * 2}'; }
class C12 { @pragma('maot:mutable') String v(int x) => 'C12:${x * 2}'; }
class C13 { @pragma('maot:mutable') String v(int x) => 'C13:${x * 2}'; }
class C14 { @pragma('maot:mutable') String v(int x) => 'C14:${x * 2}'; }
class C15 { @pragma('maot:mutable') String v(int x) => 'C15:${x * 2}'; }
class C16 { @pragma('maot:mutable') String v(int x) => 'C16:${x * 2}'; }
class C17 { @pragma('maot:mutable') String v(int x) => 'C17:${x * 2}'; }
class C18 { @pragma('maot:mutable') String v(int x) => 'C18:${x * 2}'; }
class C19 { @pragma('maot:mutable') String v(int x) => 'C19:${x * 2}'; }
class C20 { @pragma('maot:mutable') String v(int x) => 'C20:${x * 2}'; }
class C21 { @pragma('maot:mutable') String v(int x) => 'C21:${x * 2}'; }
class C22 { @pragma('maot:mutable') String v(int x) => 'C22:${x * 2}'; }
class C23 { @pragma('maot:mutable') String v(int x) => 'C23:${x * 2}'; }
class C24 { @pragma('maot:mutable') String v(int x) => 'C24:${x * 2}'; }
class C25 { @pragma('maot:mutable') String v(int x) => 'C25:${x * 2}'; }
class C26 { @pragma('maot:mutable') String v(int x) => 'C26:${x * 2}'; }
class C27 { @pragma('maot:mutable') String v(int x) => 'C27:${x * 2}'; }
class C28 { @pragma('maot:mutable') String v(int x) => 'C28:${x * 2}'; }
class C29 { @pragma('maot:mutable') String v(int x) => 'C29:${x * 2}'; }
class C30 { @pragma('maot:mutable') String v(int x) => 'C30:${x * 2}'; }
class C31 { @pragma('maot:mutable') String v(int x) => 'C31:${x * 2}'; }
class C32 { @pragma('maot:mutable') String v(int x) => 'C32:${x * 2}'; }
class C33 { @pragma('maot:mutable') String v(int x) => 'C33:${x * 2}'; }
class C34 { @pragma('maot:mutable') String v(int x) => 'C34:${x * 2}'; }
class C35 { @pragma('maot:mutable') String v(int x) => 'C35:${x * 2}'; }
class C36 { @pragma('maot:mutable') String v(int x) => 'C36:${x * 2}'; }
class C37 { @pragma('maot:mutable') String v(int x) => 'C37:${x * 2}'; }
class C38 { @pragma('maot:mutable') String v(int x) => 'C38:${x * 2}'; }
class C39 { @pragma('maot:mutable') String v(int x) => 'C39:${x * 2}'; }
class C40 { @pragma('maot:mutable') String v(int x) => 'C40:${x * 2}'; }
class C41 { @pragma('maot:mutable') String v(int x) => 'C41:${x * 2}'; }
class C42 { @pragma('maot:mutable') String v(int x) => 'C42:${x * 2}'; }
class C43 { @pragma('maot:mutable') String v(int x) => 'C43:${x * 2}'; }
class C44 { @pragma('maot:mutable') String v(int x) => 'C44:${x * 2}'; }
class C45 { @pragma('maot:mutable') String v(int x) => 'C45:${x * 2}'; }
class C46 { @pragma('maot:mutable') String v(int x) => 'C46:${x * 2}'; }
class C47 { @pragma('maot:mutable') String v(int x) => 'C47:${x * 2}'; }
class C48 { @pragma('maot:mutable') String v(int x) => 'C48:${x * 2}'; }
class C49 { @pragma('maot:mutable') String v(int x) => 'C49:${x * 2}'; }
class C50 { @pragma('maot:mutable') String v(int x) => 'C50:${x * 2}'; }
class C51 { @pragma('maot:mutable') String v(int x) => 'C51:${x * 2}'; }
class C52 { @pragma('maot:mutable') String v(int x) => 'C52:${x * 2}'; }
class C53 { @pragma('maot:mutable') String v(int x) => 'C53:${x * 2}'; }
class C54 { @pragma('maot:mutable') String v(int x) => 'C54:${x * 2}'; }
class C55 { @pragma('maot:mutable') String v(int x) => 'C55:${x * 2}'; }
class C56 { @pragma('maot:mutable') String v(int x) => 'C56:${x * 2}'; }
class C57 { @pragma('maot:mutable') String v(int x) => 'C57:${x * 2}'; }
class C58 { @pragma('maot:mutable') String v(int x) => 'C58:${x * 2}'; }
class C59 { @pragma('maot:mutable') String v(int x) => 'C59:${x * 2}'; }
class C60 { @pragma('maot:mutable') String v(int x) => 'C60:${x * 2}'; }
class C61 { @pragma('maot:mutable') String v(int x) => 'C61:${x * 2}'; }
class C62 { @pragma('maot:mutable') String v(int x) => 'C62:${x * 2}'; }
class C63 { @pragma('maot:mutable') String v(int x) => 'C63:${x * 2}'; }
class C64 { @pragma('maot:mutable') String v(int x) => 'C64:${x * 2}'; }
class C65 { @pragma('maot:mutable') String v(int x) => 'C65:${x * 2}'; }
class C66 { @pragma('maot:mutable') String v(int x) => 'C66:${x * 2}'; }
class C67 { @pragma('maot:mutable') String v(int x) => 'C67:${x * 2}'; }
class C68 { @pragma('maot:mutable') String v(int x) => 'C68:${x * 2}'; }
class C69 { @pragma('maot:mutable') String v(int x) => 'C69:${x * 2}'; }
class C70 { @pragma('maot:mutable') String v(int x) => 'C70:${x * 2}'; }
class C71 { @pragma('maot:mutable') String v(int x) => 'C71:${x * 2}'; }
class C72 { @pragma('maot:mutable') String v(int x) => 'C72:${x * 2}'; }
class C73 { @pragma('maot:mutable') String v(int x) => 'C73:${x * 2}'; }
class C74 { @pragma('maot:mutable') String v(int x) => 'C74:${x * 2}'; }
class C75 { @pragma('maot:mutable') String v(int x) => 'C75:${x * 2}'; }
class C76 { @pragma('maot:mutable') String v(int x) => 'C76:${x * 2}'; }
class C77 { @pragma('maot:mutable') String v(int x) => 'C77:${x * 2}'; }
class C78 { @pragma('maot:mutable') String v(int x) => 'C78:${x * 2}'; }
class C79 { @pragma('maot:mutable') String v(int x) => 'C79:${x * 2}'; }
class C80 { @pragma('maot:mutable') String v(int x) => 'C80:${x * 2}'; }
class C81 { @pragma('maot:mutable') String v(int x) => 'C81:${x * 2}'; }
class C82 { @pragma('maot:mutable') String v(int x) => 'C82:${x * 2}'; }
class C83 { @pragma('maot:mutable') String v(int x) => 'C83:${x * 2}'; }
class C84 { @pragma('maot:mutable') String v(int x) => 'C84:${x * 2}'; }
class C85 { @pragma('maot:mutable') String v(int x) => 'C85:${x * 2}'; }
class C86 { @pragma('maot:mutable') String v(int x) => 'C86:${x * 2}'; }
class C87 { @pragma('maot:mutable') String v(int x) => 'C87:${x * 2}'; }
class C88 { @pragma('maot:mutable') String v(int x) => 'C88:${x * 2}'; }
class C89 { @pragma('maot:mutable') String v(int x) => 'C89:${x * 2}'; }
class C90 { @pragma('maot:mutable') String v(int x) => 'C90:${x * 2}'; }
class C91 { @pragma('maot:mutable') String v(int x) => 'C91:${x * 2}'; }
class C92 { @pragma('maot:mutable') String v(int x) => 'C92:${x * 2}'; }
class C93 { @pragma('maot:mutable') String v(int x) => 'C93:${x * 2}'; }
class C94 { @pragma('maot:mutable') String v(int x) => 'C94:${x * 2}'; }
class C95 { @pragma('maot:mutable') String v(int x) => 'C95:${x * 2}'; }
class C96 { @pragma('maot:mutable') String v(int x) => 'C96:${x * 2}'; }
class C97 { @pragma('maot:mutable') String v(int x) => 'C97:${x * 2}'; }
class C98 { @pragma('maot:mutable') String v(int x) => 'C98:${x * 2}'; }
class C99 { @pragma('maot:mutable') String v(int x) => 'C99:${x * 2}'; }
class C100 { @pragma('maot:mutable') String v(int x) => 'C100:${x * 2}'; }
class C101 { @pragma('maot:mutable') String v(int x) => 'C101:${x * 2}'; }
class C102 { @pragma('maot:mutable') String v(int x) => 'C102:${x * 2}'; }
class C103 { @pragma('maot:mutable') String v(int x) => 'C103:${x * 2}'; }
class C104 { @pragma('maot:mutable') String v(int x) => 'C104:${x * 2}'; }
class C105 { @pragma('maot:mutable') String v(int x) => 'C105:${x * 2}'; }
class C106 { @pragma('maot:mutable') String v(int x) => 'C106:${x * 2}'; }
class C107 { @pragma('maot:mutable') String v(int x) => 'C107:${x * 2}'; }
class C108 { @pragma('maot:mutable') String v(int x) => 'C108:${x * 2}'; }
class C109 { @pragma('maot:mutable') String v(int x) => 'C109:${x * 2}'; }
class C110 { @pragma('maot:mutable') String v(int x) => 'C110:${x * 2}'; }
class C111 { @pragma('maot:mutable') String v(int x) => 'C111:${x * 2}'; }
class C112 { @pragma('maot:mutable') String v(int x) => 'C112:${x * 2}'; }
class C113 { @pragma('maot:mutable') String v(int x) => 'C113:${x * 2}'; }
class C114 { @pragma('maot:mutable') String v(int x) => 'C114:${x * 2}'; }
class C115 { @pragma('maot:mutable') String v(int x) => 'C115:${x * 2}'; }
class C116 { @pragma('maot:mutable') String v(int x) => 'C116:${x * 2}'; }
class C117 { @pragma('maot:mutable') String v(int x) => 'C117:${x * 2}'; }
class C118 { @pragma('maot:mutable') String v(int x) => 'C118:${x * 2}'; }
class C119 { @pragma('maot:mutable') String v(int x) => 'C119:${x * 2}'; }
class C120 { @pragma('maot:mutable') String v(int x) => 'C120:${x * 2}'; }
class C121 { @pragma('maot:mutable') String v(int x) => 'C121:${x * 2}'; }
class C122 { @pragma('maot:mutable') String v(int x) => 'C122:${x * 2}'; }
class C123 { @pragma('maot:mutable') String v(int x) => 'C123:${x * 2}'; }
class C124 { @pragma('maot:mutable') String v(int x) => 'C124:${x * 2}'; }
class C125 { @pragma('maot:mutable') String v(int x) => 'C125:${x * 2}'; }
class C126 { @pragma('maot:mutable') String v(int x) => 'C126:${x * 2}'; }
class C127 { @pragma('maot:mutable') String v(int x) => 'C127:${x * 2}'; }
class C128 { @pragma('maot:mutable') String v(int x) => 'C128:${x * 2}'; }
class C129 { @pragma('maot:mutable') String v(int x) => 'C129:${x * 2}'; }
class C130 { @pragma('maot:mutable') String v(int x) => 'C130:${x * 2}'; }
class C131 { @pragma('maot:mutable') String v(int x) => 'C131:${x * 2}'; }
class C132 { @pragma('maot:mutable') String v(int x) => 'C132:${x * 2}'; }
class C133 { @pragma('maot:mutable') String v(int x) => 'C133:${x * 2}'; }
class C134 { @pragma('maot:mutable') String v(int x) => 'C134:${x * 2}'; }
class C135 { @pragma('maot:mutable') String v(int x) => 'C135:${x * 2}'; }
class C136 { @pragma('maot:mutable') String v(int x) => 'C136:${x * 2}'; }
class C137 { @pragma('maot:mutable') String v(int x) => 'C137:${x * 2}'; }
class C138 { @pragma('maot:mutable') String v(int x) => 'C138:${x * 2}'; }
class C139 { @pragma('maot:mutable') String v(int x) => 'C139:${x * 2}'; }
class C140 { @pragma('maot:mutable') String v(int x) => 'C140:${x * 2}'; }
class C141 { @pragma('maot:mutable') String v(int x) => 'C141:${x * 2}'; }
class C142 { @pragma('maot:mutable') String v(int x) => 'C142:${x * 2}'; }
class C143 { @pragma('maot:mutable') String v(int x) => 'C143:${x * 2}'; }
class C144 { @pragma('maot:mutable') String v(int x) => 'C144:${x * 2}'; }
class C145 { @pragma('maot:mutable') String v(int x) => 'C145:${x * 2}'; }
class C146 { @pragma('maot:mutable') String v(int x) => 'C146:${x * 2}'; }
class C147 { @pragma('maot:mutable') String v(int x) => 'C147:${x * 2}'; }
class C148 { @pragma('maot:mutable') String v(int x) => 'C148:${x * 2}'; }
class C149 { @pragma('maot:mutable') String v(int x) => 'C149:${x * 2}'; }
class C150 { @pragma('maot:mutable') String v(int x) => 'C150:${x * 2}'; }
class C151 { @pragma('maot:mutable') String v(int x) => 'C151:${x * 2}'; }
class C152 { @pragma('maot:mutable') String v(int x) => 'C152:${x * 2}'; }
class C153 { @pragma('maot:mutable') String v(int x) => 'C153:${x * 2}'; }
class C154 { @pragma('maot:mutable') String v(int x) => 'C154:${x * 2}'; }
class C155 { @pragma('maot:mutable') String v(int x) => 'C155:${x * 2}'; }
class C156 { @pragma('maot:mutable') String v(int x) => 'C156:${x * 2}'; }
class C157 { @pragma('maot:mutable') String v(int x) => 'C157:${x * 2}'; }
class C158 { @pragma('maot:mutable') String v(int x) => 'C158:${x * 2}'; }
class C159 { @pragma('maot:mutable') String v(int x) => 'C159:${x * 2}'; }
class C160 { @pragma('maot:mutable') String v(int x) => 'C160:${x * 2}'; }
class C161 { @pragma('maot:mutable') String v(int x) => 'C161:${x * 2}'; }
class C162 { @pragma('maot:mutable') String v(int x) => 'C162:${x * 2}'; }
class C163 { @pragma('maot:mutable') String v(int x) => 'C163:${x * 2}'; }
class C164 { @pragma('maot:mutable') String v(int x) => 'C164:${x * 2}'; }
class C165 { @pragma('maot:mutable') String v(int x) => 'C165:${x * 2}'; }
class C166 { @pragma('maot:mutable') String v(int x) => 'C166:${x * 2}'; }
class C167 { @pragma('maot:mutable') String v(int x) => 'C167:${x * 2}'; }
class C168 { @pragma('maot:mutable') String v(int x) => 'C168:${x * 2}'; }
class C169 { @pragma('maot:mutable') String v(int x) => 'C169:${x * 2}'; }
class C170 { @pragma('maot:mutable') String v(int x) => 'C170:${x * 2}'; }
class C171 { @pragma('maot:mutable') String v(int x) => 'C171:${x * 2}'; }
class C172 { @pragma('maot:mutable') String v(int x) => 'C172:${x * 2}'; }
class C173 { @pragma('maot:mutable') String v(int x) => 'C173:${x * 2}'; }
class C174 { @pragma('maot:mutable') String v(int x) => 'C174:${x * 2}'; }
class C175 { @pragma('maot:mutable') String v(int x) => 'C175:${x * 2}'; }
class C176 { @pragma('maot:mutable') String v(int x) => 'C176:${x * 2}'; }
class C177 { @pragma('maot:mutable') String v(int x) => 'C177:${x * 2}'; }
class C178 { @pragma('maot:mutable') String v(int x) => 'C178:${x * 2}'; }
class C179 { @pragma('maot:mutable') String v(int x) => 'C179:${x * 2}'; }
class C180 { @pragma('maot:mutable') String v(int x) => 'C180:${x * 2}'; }
class C181 { @pragma('maot:mutable') String v(int x) => 'C181:${x * 2}'; }
class C182 { @pragma('maot:mutable') String v(int x) => 'C182:${x * 2}'; }
class C183 { @pragma('maot:mutable') String v(int x) => 'C183:${x * 2}'; }
class C184 { @pragma('maot:mutable') String v(int x) => 'C184:${x * 2}'; }
class C185 { @pragma('maot:mutable') String v(int x) => 'C185:${x * 2}'; }
class C186 { @pragma('maot:mutable') String v(int x) => 'C186:${x * 2}'; }
class C187 { @pragma('maot:mutable') String v(int x) => 'C187:${x * 2}'; }
class C188 { @pragma('maot:mutable') String v(int x) => 'C188:${x * 2}'; }
class C189 { @pragma('maot:mutable') String v(int x) => 'C189:${x * 2}'; }
class C190 { @pragma('maot:mutable') String v(int x) => 'C190:${x * 2}'; }
class C191 { @pragma('maot:mutable') String v(int x) => 'C191:${x * 2}'; }
class C192 { @pragma('maot:mutable') String v(int x) => 'C192:${x * 2}'; }
class C193 { @pragma('maot:mutable') String v(int x) => 'C193:${x * 2}'; }
class C194 { @pragma('maot:mutable') String v(int x) => 'C194:${x * 2}'; }
class C195 { @pragma('maot:mutable') String v(int x) => 'C195:${x * 2}'; }
class C196 { @pragma('maot:mutable') String v(int x) => 'C196:${x * 2}'; }
class C197 { @pragma('maot:mutable') String v(int x) => 'C197:${x * 2}'; }
class C198 { @pragma('maot:mutable') String v(int x) => 'C198:${x * 2}'; }
class C199 { @pragma('maot:mutable') String v(int x) => 'C199:${x * 2}'; }
class C200 { @pragma('maot:mutable') String v(int x) => 'C200:${x * 2}'; }
class C201 { @pragma('maot:mutable') String v(int x) => 'C201:${x * 2}'; }
class C202 { @pragma('maot:mutable') String v(int x) => 'C202:${x * 2}'; }
class C203 { @pragma('maot:mutable') String v(int x) => 'C203:${x * 2}'; }
class C204 { @pragma('maot:mutable') String v(int x) => 'C204:${x * 2}'; }
class C205 { @pragma('maot:mutable') String v(int x) => 'C205:${x * 2}'; }
class C206 { @pragma('maot:mutable') String v(int x) => 'C206:${x * 2}'; }
class C207 { @pragma('maot:mutable') String v(int x) => 'C207:${x * 2}'; }
class C208 { @pragma('maot:mutable') String v(int x) => 'C208:${x * 2}'; }
class C209 { @pragma('maot:mutable') String v(int x) => 'C209:${x * 2}'; }
class C210 { @pragma('maot:mutable') String v(int x) => 'C210:${x * 2}'; }
class C211 { @pragma('maot:mutable') String v(int x) => 'C211:${x * 2}'; }
class C212 { @pragma('maot:mutable') String v(int x) => 'C212:${x * 2}'; }
class C213 { @pragma('maot:mutable') String v(int x) => 'C213:${x * 2}'; }
class C214 { @pragma('maot:mutable') String v(int x) => 'C214:${x * 2}'; }
class C215 { @pragma('maot:mutable') String v(int x) => 'C215:${x * 2}'; }
class C216 { @pragma('maot:mutable') String v(int x) => 'C216:${x * 2}'; }
class C217 { @pragma('maot:mutable') String v(int x) => 'C217:${x * 2}'; }
class C218 { @pragma('maot:mutable') String v(int x) => 'C218:${x * 2}'; }
class C219 { @pragma('maot:mutable') String v(int x) => 'C219:${x * 2}'; }
class C220 { @pragma('maot:mutable') String v(int x) => 'C220:${x * 2}'; }
class C221 { @pragma('maot:mutable') String v(int x) => 'C221:${x * 2}'; }
class C222 { @pragma('maot:mutable') String v(int x) => 'C222:${x * 2}'; }
class C223 { @pragma('maot:mutable') String v(int x) => 'C223:${x * 2}'; }
class C224 { @pragma('maot:mutable') String v(int x) => 'C224:${x * 2}'; }
class C225 { @pragma('maot:mutable') String v(int x) => 'C225:${x * 2}'; }
class C226 { @pragma('maot:mutable') String v(int x) => 'C226:${x * 2}'; }
class C227 { @pragma('maot:mutable') String v(int x) => 'C227:${x * 2}'; }
class C228 { @pragma('maot:mutable') String v(int x) => 'C228:${x * 2}'; }
class C229 { @pragma('maot:mutable') String v(int x) => 'C229:${x * 2}'; }
class C230 { @pragma('maot:mutable') String v(int x) => 'C230:${x * 2}'; }
class C231 { @pragma('maot:mutable') String v(int x) => 'C231:${x * 2}'; }
class C232 { @pragma('maot:mutable') String v(int x) => 'C232:${x * 2}'; }
class C233 { @pragma('maot:mutable') String v(int x) => 'C233:${x * 2}'; }
class C234 { @pragma('maot:mutable') String v(int x) => 'C234:${x * 2}'; }
class C235 { @pragma('maot:mutable') String v(int x) => 'C235:${x * 2}'; }
class C236 { @pragma('maot:mutable') String v(int x) => 'C236:${x * 2}'; }
class C237 { @pragma('maot:mutable') String v(int x) => 'C237:${x * 2}'; }
class C238 { @pragma('maot:mutable') String v(int x) => 'C238:${x * 2}'; }
class C239 { @pragma('maot:mutable') String v(int x) => 'C239:${x * 2}'; }
class C240 { @pragma('maot:mutable') String v(int x) => 'C240:${x * 2}'; }
class C241 { @pragma('maot:mutable') String v(int x) => 'C241:${x * 2}'; }
class C242 { @pragma('maot:mutable') String v(int x) => 'C242:${x * 2}'; }
class C243 { @pragma('maot:mutable') String v(int x) => 'C243:${x * 2}'; }
class C244 { @pragma('maot:mutable') String v(int x) => 'C244:${x * 2}'; }
class C245 { @pragma('maot:mutable') String v(int x) => 'C245:${x * 2}'; }
class C246 { @pragma('maot:mutable') String v(int x) => 'C246:${x * 2}'; }
class C247 { @pragma('maot:mutable') String v(int x) => 'C247:${x * 2}'; }
class C248 { @pragma('maot:mutable') String v(int x) => 'C248:${x * 2}'; }
class C249 { @pragma('maot:mutable') String v(int x) => 'C249:${x * 2}'; }
class C250 { @pragma('maot:mutable') String v(int x) => 'C250:${x * 2}'; }
class C251 { @pragma('maot:mutable') String v(int x) => 'C251:${x * 2}'; }
class C252 { @pragma('maot:mutable') String v(int x) => 'C252:${x * 2}'; }
class C253 { @pragma('maot:mutable') String v(int x) => 'C253:${x * 2}'; }
class C254 { @pragma('maot:mutable') String v(int x) => 'C254:${x * 2}'; }
class C255 { @pragma('maot:mutable') String v(int x) => 'C255:${x * 2}'; }
class C256 { @pragma('maot:mutable') String v(int x) => 'C256:${x * 2}'; }
class C257 { @pragma('maot:mutable') String v(int x) => 'C257:${x * 2}'; }
class C258 { @pragma('maot:mutable') String v(int x) => 'C258:${x * 2}'; }
class C259 { @pragma('maot:mutable') String v(int x) => 'C259:${x * 2}'; }
class C260 { @pragma('maot:mutable') String v(int x) => 'C260:${x * 2}'; }
class C261 { @pragma('maot:mutable') String v(int x) => 'C261:${x * 2}'; }
class C262 { @pragma('maot:mutable') String v(int x) => 'C262:${x * 2}'; }
class C263 { @pragma('maot:mutable') String v(int x) => 'C263:${x * 2}'; }
class C264 { @pragma('maot:mutable') String v(int x) => 'C264:${x * 2}'; }
class C265 { @pragma('maot:mutable') String v(int x) => 'C265:${x * 2}'; }
class C266 { @pragma('maot:mutable') String v(int x) => 'C266:${x * 2}'; }
class C267 { @pragma('maot:mutable') String v(int x) => 'C267:${x * 2}'; }
class C268 { @pragma('maot:mutable') String v(int x) => 'C268:${x * 2}'; }
class C269 { @pragma('maot:mutable') String v(int x) => 'C269:${x * 2}'; }
class C270 { @pragma('maot:mutable') String v(int x) => 'C270:${x * 2}'; }
class C271 { @pragma('maot:mutable') String v(int x) => 'C271:${x * 2}'; }
class C272 { @pragma('maot:mutable') String v(int x) => 'C272:${x * 2}'; }
class C273 { @pragma('maot:mutable') String v(int x) => 'C273:${x * 2}'; }
class C274 { @pragma('maot:mutable') String v(int x) => 'C274:${x * 2}'; }
class C275 { @pragma('maot:mutable') String v(int x) => 'C275:${x * 2}'; }
class C276 { @pragma('maot:mutable') String v(int x) => 'C276:${x * 2}'; }
class C277 { @pragma('maot:mutable') String v(int x) => 'C277:${x * 2}'; }
class C278 { @pragma('maot:mutable') String v(int x) => 'C278:${x * 2}'; }
class C279 { @pragma('maot:mutable') String v(int x) => 'C279:${x * 2}'; }
class C280 { @pragma('maot:mutable') String v(int x) => 'C280:${x * 2}'; }
class C281 { @pragma('maot:mutable') String v(int x) => 'C281:${x * 2}'; }
class C282 { @pragma('maot:mutable') String v(int x) => 'C282:${x * 2}'; }
class C283 { @pragma('maot:mutable') String v(int x) => 'C283:${x * 2}'; }
class C284 { @pragma('maot:mutable') String v(int x) => 'C284:${x * 2}'; }
class C285 { @pragma('maot:mutable') String v(int x) => 'C285:${x * 2}'; }
class C286 { @pragma('maot:mutable') String v(int x) => 'C286:${x * 2}'; }
class C287 { @pragma('maot:mutable') String v(int x) => 'C287:${x * 2}'; }
class C288 { @pragma('maot:mutable') String v(int x) => 'C288:${x * 2}'; }
class C289 { @pragma('maot:mutable') String v(int x) => 'C289:${x * 2}'; }
class C290 { @pragma('maot:mutable') String v(int x) => 'C290:${x * 2}'; }
class C291 { @pragma('maot:mutable') String v(int x) => 'C291:${x * 2}'; }
class C292 { @pragma('maot:mutable') String v(int x) => 'C292:${x * 2}'; }
class C293 { @pragma('maot:mutable') String v(int x) => 'C293:${x * 2}'; }
class C294 { @pragma('maot:mutable') String v(int x) => 'C294:${x * 2}'; }
class C295 { @pragma('maot:mutable') String v(int x) => 'C295:${x * 2}'; }
class C296 { @pragma('maot:mutable') String v(int x) => 'C296:${x * 2}'; }
class C297 { @pragma('maot:mutable') String v(int x) => 'C297:${x * 2}'; }
class C298 { @pragma('maot:mutable') String v(int x) => 'C298:${x * 2}'; }
class C299 { @pragma('maot:mutable') String v(int x) => 'C299:${x * 2}'; }
class C300 { @pragma('maot:mutable') String v(int x) => 'C300:${x * 2}'; }
class C301 { @pragma('maot:mutable') String v(int x) => 'C301:${x * 2}'; }
class C302 { @pragma('maot:mutable') String v(int x) => 'C302:${x * 2}'; }
class C303 { @pragma('maot:mutable') String v(int x) => 'C303:${x * 2}'; }
class C304 { @pragma('maot:mutable') String v(int x) => 'C304:${x * 2}'; }
class C305 { @pragma('maot:mutable') String v(int x) => 'C305:${x * 2}'; }
class C306 { @pragma('maot:mutable') String v(int x) => 'C306:${x * 2}'; }
class C307 { @pragma('maot:mutable') String v(int x) => 'C307:${x * 2}'; }
class C308 { @pragma('maot:mutable') String v(int x) => 'C308:${x * 2}'; }
class C309 { @pragma('maot:mutable') String v(int x) => 'C309:${x * 2}'; }
class C310 { @pragma('maot:mutable') String v(int x) => 'C310:${x * 2}'; }
class C311 { @pragma('maot:mutable') String v(int x) => 'C311:${x * 2}'; }
class C312 { @pragma('maot:mutable') String v(int x) => 'C312:${x * 2}'; }
class C313 { @pragma('maot:mutable') String v(int x) => 'C313:${x * 2}'; }
class C314 { @pragma('maot:mutable') String v(int x) => 'C314:${x * 2}'; }
class C315 { @pragma('maot:mutable') String v(int x) => 'C315:${x * 2}'; }
class C316 { @pragma('maot:mutable') String v(int x) => 'C316:${x * 2}'; }
class C317 { @pragma('maot:mutable') String v(int x) => 'C317:${x * 2}'; }
class C318 { @pragma('maot:mutable') String v(int x) => 'C318:${x * 2}'; }
class C319 { @pragma('maot:mutable') String v(int x) => 'C319:${x * 2}'; }
class C320 { @pragma('maot:mutable') String v(int x) => 'C320:${x * 2}'; }
class C321 { @pragma('maot:mutable') String v(int x) => 'C321:${x * 2}'; }
class C322 { @pragma('maot:mutable') String v(int x) => 'C322:${x * 2}'; }
class C323 { @pragma('maot:mutable') String v(int x) => 'C323:${x * 2}'; }
class C324 { @pragma('maot:mutable') String v(int x) => 'C324:${x * 2}'; }
class C325 { @pragma('maot:mutable') String v(int x) => 'C325:${x * 2}'; }
class C326 { @pragma('maot:mutable') String v(int x) => 'C326:${x * 2}'; }
class C327 { @pragma('maot:mutable') String v(int x) => 'C327:${x * 2}'; }
class C328 { @pragma('maot:mutable') String v(int x) => 'C328:${x * 2}'; }
class C329 { @pragma('maot:mutable') String v(int x) => 'C329:${x * 2}'; }
class C330 { @pragma('maot:mutable') String v(int x) => 'C330:${x * 2}'; }
class C331 { @pragma('maot:mutable') String v(int x) => 'C331:${x * 2}'; }
class C332 { @pragma('maot:mutable') String v(int x) => 'C332:${x * 2}'; }
class C333 { @pragma('maot:mutable') String v(int x) => 'C333:${x * 2}'; }
class C334 { @pragma('maot:mutable') String v(int x) => 'C334:${x * 2}'; }
class C335 { @pragma('maot:mutable') String v(int x) => 'C335:${x * 2}'; }
class C336 { @pragma('maot:mutable') String v(int x) => 'C336:${x * 2}'; }
class C337 { @pragma('maot:mutable') String v(int x) => 'C337:${x * 2}'; }
class C338 { @pragma('maot:mutable') String v(int x) => 'C338:${x * 2}'; }
class C339 { @pragma('maot:mutable') String v(int x) => 'C339:${x * 2}'; }
class C340 { @pragma('maot:mutable') String v(int x) => 'C340:${x * 2}'; }
class C341 { @pragma('maot:mutable') String v(int x) => 'C341:${x * 2}'; }
class C342 { @pragma('maot:mutable') String v(int x) => 'C342:${x * 2}'; }
class C343 { @pragma('maot:mutable') String v(int x) => 'C343:${x * 2}'; }
class C344 { @pragma('maot:mutable') String v(int x) => 'C344:${x * 2}'; }
class C345 { @pragma('maot:mutable') String v(int x) => 'C345:${x * 2}'; }
class C346 { @pragma('maot:mutable') String v(int x) => 'C346:${x * 2}'; }
class C347 { @pragma('maot:mutable') String v(int x) => 'C347:${x * 2}'; }
class C348 { @pragma('maot:mutable') String v(int x) => 'C348:${x * 2}'; }
class C349 { @pragma('maot:mutable') String v(int x) => 'C349:${x * 2}'; }
class C350 { @pragma('maot:mutable') String v(int x) => 'C350:${x * 2}'; }
class C351 { @pragma('maot:mutable') String v(int x) => 'C351:${x * 2}'; }
class C352 { @pragma('maot:mutable') String v(int x) => 'C352:${x * 2}'; }
class C353 { @pragma('maot:mutable') String v(int x) => 'C353:${x * 2}'; }
class C354 { @pragma('maot:mutable') String v(int x) => 'C354:${x * 2}'; }
class C355 { @pragma('maot:mutable') String v(int x) => 'C355:${x * 2}'; }
class C356 { @pragma('maot:mutable') String v(int x) => 'C356:${x * 2}'; }
class C357 { @pragma('maot:mutable') String v(int x) => 'C357:${x * 2}'; }
class C358 { @pragma('maot:mutable') String v(int x) => 'C358:${x * 2}'; }
class C359 { @pragma('maot:mutable') String v(int x) => 'C359:${x * 2}'; }
class C360 { @pragma('maot:mutable') String v(int x) => 'C360:${x * 2}'; }
class C361 { @pragma('maot:mutable') String v(int x) => 'C361:${x * 2}'; }
class C362 { @pragma('maot:mutable') String v(int x) => 'C362:${x * 2}'; }
class C363 { @pragma('maot:mutable') String v(int x) => 'C363:${x * 2}'; }
class C364 { @pragma('maot:mutable') String v(int x) => 'C364:${x * 2}'; }
class C365 { @pragma('maot:mutable') String v(int x) => 'C365:${x * 2}'; }
class C366 { @pragma('maot:mutable') String v(int x) => 'C366:${x * 2}'; }
class C367 { @pragma('maot:mutable') String v(int x) => 'C367:${x * 2}'; }
class C368 { @pragma('maot:mutable') String v(int x) => 'C368:${x * 2}'; }
class C369 { @pragma('maot:mutable') String v(int x) => 'C369:${x * 2}'; }
class C370 { @pragma('maot:mutable') String v(int x) => 'C370:${x * 2}'; }
class C371 { @pragma('maot:mutable') String v(int x) => 'C371:${x * 2}'; }
class C372 { @pragma('maot:mutable') String v(int x) => 'C372:${x * 2}'; }
class C373 { @pragma('maot:mutable') String v(int x) => 'C373:${x * 2}'; }
class C374 { @pragma('maot:mutable') String v(int x) => 'C374:${x * 2}'; }
class C375 { @pragma('maot:mutable') String v(int x) => 'C375:${x * 2}'; }
class C376 { @pragma('maot:mutable') String v(int x) => 'C376:${x * 2}'; }
class C377 { @pragma('maot:mutable') String v(int x) => 'C377:${x * 2}'; }
class C378 { @pragma('maot:mutable') String v(int x) => 'C378:${x * 2}'; }
class C379 { @pragma('maot:mutable') String v(int x) => 'C379:${x * 2}'; }
class C380 { @pragma('maot:mutable') String v(int x) => 'C380:${x * 2}'; }
class C381 { @pragma('maot:mutable') String v(int x) => 'C381:${x * 2}'; }
class C382 { @pragma('maot:mutable') String v(int x) => 'C382:${x * 2}'; }
class C383 { @pragma('maot:mutable') String v(int x) => 'C383:${x * 2}'; }
class C384 { @pragma('maot:mutable') String v(int x) => 'C384:${x * 2}'; }
class C385 { @pragma('maot:mutable') String v(int x) => 'C385:${x * 2}'; }
class C386 { @pragma('maot:mutable') String v(int x) => 'C386:${x * 2}'; }
class C387 { @pragma('maot:mutable') String v(int x) => 'C387:${x * 2}'; }
class C388 { @pragma('maot:mutable') String v(int x) => 'C388:${x * 2}'; }
class C389 { @pragma('maot:mutable') String v(int x) => 'C389:${x * 2}'; }
class C390 { @pragma('maot:mutable') String v(int x) => 'C390:${x * 2}'; }
class C391 { @pragma('maot:mutable') String v(int x) => 'C391:${x * 2}'; }
class C392 { @pragma('maot:mutable') String v(int x) => 'C392:${x * 2}'; }
class C393 { @pragma('maot:mutable') String v(int x) => 'C393:${x * 2}'; }
class C394 { @pragma('maot:mutable') String v(int x) => 'C394:${x * 2}'; }
class C395 { @pragma('maot:mutable') String v(int x) => 'C395:${x * 2}'; }
class C396 { @pragma('maot:mutable') String v(int x) => 'C396:${x * 2}'; }
class C397 { @pragma('maot:mutable') String v(int x) => 'C397:${x * 2}'; }
class C398 { @pragma('maot:mutable') String v(int x) => 'C398:${x * 2}'; }
class C399 { @pragma('maot:mutable') String v(int x) => 'C399:${x * 2}'; }
class C400 { @pragma('maot:mutable') String v(int x) => 'C400:${x * 2}'; }
class C401 { @pragma('maot:mutable') String v(int x) => 'C401:${x * 2}'; }
class C402 { @pragma('maot:mutable') String v(int x) => 'C402:${x * 2}'; }
class C403 { @pragma('maot:mutable') String v(int x) => 'C403:${x * 2}'; }
class C404 { @pragma('maot:mutable') String v(int x) => 'C404:${x * 2}'; }
class C405 { @pragma('maot:mutable') String v(int x) => 'C405:${x * 2}'; }
class C406 { @pragma('maot:mutable') String v(int x) => 'C406:${x * 2}'; }
class C407 { @pragma('maot:mutable') String v(int x) => 'C407:${x * 2}'; }
class C408 { @pragma('maot:mutable') String v(int x) => 'C408:${x * 2}'; }
class C409 { @pragma('maot:mutable') String v(int x) => 'C409:${x * 2}'; }
class C410 { @pragma('maot:mutable') String v(int x) => 'C410:${x * 2}'; }
class C411 { @pragma('maot:mutable') String v(int x) => 'C411:${x * 2}'; }
class C412 { @pragma('maot:mutable') String v(int x) => 'C412:${x * 2}'; }
class C413 { @pragma('maot:mutable') String v(int x) => 'C413:${x * 2}'; }
class C414 { @pragma('maot:mutable') String v(int x) => 'C414:${x * 2}'; }
class C415 { @pragma('maot:mutable') String v(int x) => 'C415:${x * 2}'; }
class C416 { @pragma('maot:mutable') String v(int x) => 'C416:${x * 2}'; }
class C417 { @pragma('maot:mutable') String v(int x) => 'C417:${x * 2}'; }
class C418 { @pragma('maot:mutable') String v(int x) => 'C418:${x * 2}'; }
class C419 { @pragma('maot:mutable') String v(int x) => 'C419:${x * 2}'; }
class C420 { @pragma('maot:mutable') String v(int x) => 'C420:${x * 2}'; }
class C421 { @pragma('maot:mutable') String v(int x) => 'C421:${x * 2}'; }
class C422 { @pragma('maot:mutable') String v(int x) => 'C422:${x * 2}'; }
class C423 { @pragma('maot:mutable') String v(int x) => 'C423:${x * 2}'; }
class C424 { @pragma('maot:mutable') String v(int x) => 'C424:${x * 2}'; }
class C425 { @pragma('maot:mutable') String v(int x) => 'C425:${x * 2}'; }
class C426 { @pragma('maot:mutable') String v(int x) => 'C426:${x * 2}'; }
class C427 { @pragma('maot:mutable') String v(int x) => 'C427:${x * 2}'; }
class C428 { @pragma('maot:mutable') String v(int x) => 'C428:${x * 2}'; }
class C429 { @pragma('maot:mutable') String v(int x) => 'C429:${x * 2}'; }
class C430 { @pragma('maot:mutable') String v(int x) => 'C430:${x * 2}'; }
class C431 { @pragma('maot:mutable') String v(int x) => 'C431:${x * 2}'; }
class C432 { @pragma('maot:mutable') String v(int x) => 'C432:${x * 2}'; }
class C433 { @pragma('maot:mutable') String v(int x) => 'C433:${x * 2}'; }
class C434 { @pragma('maot:mutable') String v(int x) => 'C434:${x * 2}'; }
class C435 { @pragma('maot:mutable') String v(int x) => 'C435:${x * 2}'; }
class C436 { @pragma('maot:mutable') String v(int x) => 'C436:${x * 2}'; }
class C437 { @pragma('maot:mutable') String v(int x) => 'C437:${x * 2}'; }
class C438 { @pragma('maot:mutable') String v(int x) => 'C438:${x * 2}'; }
class C439 { @pragma('maot:mutable') String v(int x) => 'C439:${x * 2}'; }
class C440 { @pragma('maot:mutable') String v(int x) => 'C440:${x * 2}'; }
class C441 { @pragma('maot:mutable') String v(int x) => 'C441:${x * 2}'; }
class C442 { @pragma('maot:mutable') String v(int x) => 'C442:${x * 2}'; }
class C443 { @pragma('maot:mutable') String v(int x) => 'C443:${x * 2}'; }
class C444 { @pragma('maot:mutable') String v(int x) => 'C444:${x * 2}'; }
class C445 { @pragma('maot:mutable') String v(int x) => 'C445:${x * 2}'; }
class C446 { @pragma('maot:mutable') String v(int x) => 'C446:${x * 2}'; }
class C447 { @pragma('maot:mutable') String v(int x) => 'C447:${x * 2}'; }
class C448 { @pragma('maot:mutable') String v(int x) => 'C448:${x * 2}'; }
class C449 { @pragma('maot:mutable') String v(int x) => 'C449:${x * 2}'; }
class C450 { @pragma('maot:mutable') String v(int x) => 'C450:${x * 2}'; }
class C451 { @pragma('maot:mutable') String v(int x) => 'C451:${x * 2}'; }
class C452 { @pragma('maot:mutable') String v(int x) => 'C452:${x * 2}'; }
class C453 { @pragma('maot:mutable') String v(int x) => 'C453:${x * 2}'; }
class C454 { @pragma('maot:mutable') String v(int x) => 'C454:${x * 2}'; }
class C455 { @pragma('maot:mutable') String v(int x) => 'C455:${x * 2}'; }
class C456 { @pragma('maot:mutable') String v(int x) => 'C456:${x * 2}'; }
class C457 { @pragma('maot:mutable') String v(int x) => 'C457:${x * 2}'; }
class C458 { @pragma('maot:mutable') String v(int x) => 'C458:${x * 2}'; }
class C459 { @pragma('maot:mutable') String v(int x) => 'C459:${x * 2}'; }
class C460 { @pragma('maot:mutable') String v(int x) => 'C460:${x * 2}'; }
class C461 { @pragma('maot:mutable') String v(int x) => 'C461:${x * 2}'; }
class C462 { @pragma('maot:mutable') String v(int x) => 'C462:${x * 2}'; }
class C463 { @pragma('maot:mutable') String v(int x) => 'C463:${x * 2}'; }
class C464 { @pragma('maot:mutable') String v(int x) => 'C464:${x * 2}'; }
class C465 { @pragma('maot:mutable') String v(int x) => 'C465:${x * 2}'; }
class C466 { @pragma('maot:mutable') String v(int x) => 'C466:${x * 2}'; }
class C467 { @pragma('maot:mutable') String v(int x) => 'C467:${x * 2}'; }
class C468 { @pragma('maot:mutable') String v(int x) => 'C468:${x * 2}'; }
class C469 { @pragma('maot:mutable') String v(int x) => 'C469:${x * 2}'; }
class C470 { @pragma('maot:mutable') String v(int x) => 'C470:${x * 2}'; }
class C471 { @pragma('maot:mutable') String v(int x) => 'C471:${x * 2}'; }
class C472 { @pragma('maot:mutable') String v(int x) => 'C472:${x * 2}'; }
class C473 { @pragma('maot:mutable') String v(int x) => 'C473:${x * 2}'; }
class C474 { @pragma('maot:mutable') String v(int x) => 'C474:${x * 2}'; }
class C475 { @pragma('maot:mutable') String v(int x) => 'C475:${x * 2}'; }
class C476 { @pragma('maot:mutable') String v(int x) => 'C476:${x * 2}'; }
class C477 { @pragma('maot:mutable') String v(int x) => 'C477:${x * 2}'; }
class C478 { @pragma('maot:mutable') String v(int x) => 'C478:${x * 2}'; }
class C479 { @pragma('maot:mutable') String v(int x) => 'C479:${x * 2}'; }
class C480 { @pragma('maot:mutable') String v(int x) => 'C480:${x * 2}'; }
class C481 { @pragma('maot:mutable') String v(int x) => 'C481:${x * 2}'; }
class C482 { @pragma('maot:mutable') String v(int x) => 'C482:${x * 2}'; }
class C483 { @pragma('maot:mutable') String v(int x) => 'C483:${x * 2}'; }
class C484 { @pragma('maot:mutable') String v(int x) => 'C484:${x * 2}'; }
class C485 { @pragma('maot:mutable') String v(int x) => 'C485:${x * 2}'; }
class C486 { @pragma('maot:mutable') String v(int x) => 'C486:${x * 2}'; }
class C487 { @pragma('maot:mutable') String v(int x) => 'C487:${x * 2}'; }
class C488 { @pragma('maot:mutable') String v(int x) => 'C488:${x * 2}'; }
class C489 { @pragma('maot:mutable') String v(int x) => 'C489:${x * 2}'; }
class C490 { @pragma('maot:mutable') String v(int x) => 'C490:${x * 2}'; }
class C491 { @pragma('maot:mutable') String v(int x) => 'C491:${x * 2}'; }
class C492 { @pragma('maot:mutable') String v(int x) => 'C492:${x * 2}'; }
class C493 { @pragma('maot:mutable') String v(int x) => 'C493:${x * 2}'; }
class C494 { @pragma('maot:mutable') String v(int x) => 'C494:${x * 2}'; }
class C495 { @pragma('maot:mutable') String v(int x) => 'C495:${x * 2}'; }
class C496 { @pragma('maot:mutable') String v(int x) => 'C496:${x * 2}'; }
class C497 { @pragma('maot:mutable') String v(int x) => 'C497:${x * 2}'; }
class C498 { @pragma('maot:mutable') String v(int x) => 'C498:${x * 2}'; }
class C499 { @pragma('maot:mutable') String v(int x) => 'C499:${x * 2}'; }
class C500 { @pragma('maot:mutable') String v(int x) => 'C500:${x * 2}'; }
class C501 { @pragma('maot:mutable') String v(int x) => 'C501:${x * 2}'; }
class C502 { @pragma('maot:mutable') String v(int x) => 'C502:${x * 2}'; }
class C503 { @pragma('maot:mutable') String v(int x) => 'C503:${x * 2}'; }
class C504 { @pragma('maot:mutable') String v(int x) => 'C504:${x * 2}'; }
class C505 { @pragma('maot:mutable') String v(int x) => 'C505:${x * 2}'; }
class C506 { @pragma('maot:mutable') String v(int x) => 'C506:${x * 2}'; }
class C507 { @pragma('maot:mutable') String v(int x) => 'C507:${x * 2}'; }
class C508 { @pragma('maot:mutable') String v(int x) => 'C508:${x * 2}'; }
class C509 { @pragma('maot:mutable') String v(int x) => 'C509:${x * 2}'; }
class C510 { @pragma('maot:mutable') String v(int x) => 'C510:${x * 2}'; }
class C511 { @pragma('maot:mutable') String v(int x) => 'C511:${x * 2}'; }

@pragma('vm:never-inline')
dynamic mk(int i) {
  switch (i % 512) {
    case 0: return C0();
    case 1: return C1();
    case 2: return C2();
    case 3: return C3();
    case 4: return C4();
    case 5: return C5();
    case 6: return C6();
    case 7: return C7();
    case 8: return C8();
    case 9: return C9();
    case 10: return C10();
    case 11: return C11();
    case 12: return C12();
    case 13: return C13();
    case 14: return C14();
    case 15: return C15();
    case 16: return C16();
    case 17: return C17();
    case 18: return C18();
    case 19: return C19();
    case 20: return C20();
    case 21: return C21();
    case 22: return C22();
    case 23: return C23();
    case 24: return C24();
    case 25: return C25();
    case 26: return C26();
    case 27: return C27();
    case 28: return C28();
    case 29: return C29();
    case 30: return C30();
    case 31: return C31();
    case 32: return C32();
    case 33: return C33();
    case 34: return C34();
    case 35: return C35();
    case 36: return C36();
    case 37: return C37();
    case 38: return C38();
    case 39: return C39();
    case 40: return C40();
    case 41: return C41();
    case 42: return C42();
    case 43: return C43();
    case 44: return C44();
    case 45: return C45();
    case 46: return C46();
    case 47: return C47();
    case 48: return C48();
    case 49: return C49();
    case 50: return C50();
    case 51: return C51();
    case 52: return C52();
    case 53: return C53();
    case 54: return C54();
    case 55: return C55();
    case 56: return C56();
    case 57: return C57();
    case 58: return C58();
    case 59: return C59();
    case 60: return C60();
    case 61: return C61();
    case 62: return C62();
    case 63: return C63();
    case 64: return C64();
    case 65: return C65();
    case 66: return C66();
    case 67: return C67();
    case 68: return C68();
    case 69: return C69();
    case 70: return C70();
    case 71: return C71();
    case 72: return C72();
    case 73: return C73();
    case 74: return C74();
    case 75: return C75();
    case 76: return C76();
    case 77: return C77();
    case 78: return C78();
    case 79: return C79();
    case 80: return C80();
    case 81: return C81();
    case 82: return C82();
    case 83: return C83();
    case 84: return C84();
    case 85: return C85();
    case 86: return C86();
    case 87: return C87();
    case 88: return C88();
    case 89: return C89();
    case 90: return C90();
    case 91: return C91();
    case 92: return C92();
    case 93: return C93();
    case 94: return C94();
    case 95: return C95();
    case 96: return C96();
    case 97: return C97();
    case 98: return C98();
    case 99: return C99();
    case 100: return C100();
    case 101: return C101();
    case 102: return C102();
    case 103: return C103();
    case 104: return C104();
    case 105: return C105();
    case 106: return C106();
    case 107: return C107();
    case 108: return C108();
    case 109: return C109();
    case 110: return C110();
    case 111: return C111();
    case 112: return C112();
    case 113: return C113();
    case 114: return C114();
    case 115: return C115();
    case 116: return C116();
    case 117: return C117();
    case 118: return C118();
    case 119: return C119();
    case 120: return C120();
    case 121: return C121();
    case 122: return C122();
    case 123: return C123();
    case 124: return C124();
    case 125: return C125();
    case 126: return C126();
    case 127: return C127();
    case 128: return C128();
    case 129: return C129();
    case 130: return C130();
    case 131: return C131();
    case 132: return C132();
    case 133: return C133();
    case 134: return C134();
    case 135: return C135();
    case 136: return C136();
    case 137: return C137();
    case 138: return C138();
    case 139: return C139();
    case 140: return C140();
    case 141: return C141();
    case 142: return C142();
    case 143: return C143();
    case 144: return C144();
    case 145: return C145();
    case 146: return C146();
    case 147: return C147();
    case 148: return C148();
    case 149: return C149();
    case 150: return C150();
    case 151: return C151();
    case 152: return C152();
    case 153: return C153();
    case 154: return C154();
    case 155: return C155();
    case 156: return C156();
    case 157: return C157();
    case 158: return C158();
    case 159: return C159();
    case 160: return C160();
    case 161: return C161();
    case 162: return C162();
    case 163: return C163();
    case 164: return C164();
    case 165: return C165();
    case 166: return C166();
    case 167: return C167();
    case 168: return C168();
    case 169: return C169();
    case 170: return C170();
    case 171: return C171();
    case 172: return C172();
    case 173: return C173();
    case 174: return C174();
    case 175: return C175();
    case 176: return C176();
    case 177: return C177();
    case 178: return C178();
    case 179: return C179();
    case 180: return C180();
    case 181: return C181();
    case 182: return C182();
    case 183: return C183();
    case 184: return C184();
    case 185: return C185();
    case 186: return C186();
    case 187: return C187();
    case 188: return C188();
    case 189: return C189();
    case 190: return C190();
    case 191: return C191();
    case 192: return C192();
    case 193: return C193();
    case 194: return C194();
    case 195: return C195();
    case 196: return C196();
    case 197: return C197();
    case 198: return C198();
    case 199: return C199();
    case 200: return C200();
    case 201: return C201();
    case 202: return C202();
    case 203: return C203();
    case 204: return C204();
    case 205: return C205();
    case 206: return C206();
    case 207: return C207();
    case 208: return C208();
    case 209: return C209();
    case 210: return C210();
    case 211: return C211();
    case 212: return C212();
    case 213: return C213();
    case 214: return C214();
    case 215: return C215();
    case 216: return C216();
    case 217: return C217();
    case 218: return C218();
    case 219: return C219();
    case 220: return C220();
    case 221: return C221();
    case 222: return C222();
    case 223: return C223();
    case 224: return C224();
    case 225: return C225();
    case 226: return C226();
    case 227: return C227();
    case 228: return C228();
    case 229: return C229();
    case 230: return C230();
    case 231: return C231();
    case 232: return C232();
    case 233: return C233();
    case 234: return C234();
    case 235: return C235();
    case 236: return C236();
    case 237: return C237();
    case 238: return C238();
    case 239: return C239();
    case 240: return C240();
    case 241: return C241();
    case 242: return C242();
    case 243: return C243();
    case 244: return C244();
    case 245: return C245();
    case 246: return C246();
    case 247: return C247();
    case 248: return C248();
    case 249: return C249();
    case 250: return C250();
    case 251: return C251();
    case 252: return C252();
    case 253: return C253();
    case 254: return C254();
    case 255: return C255();
    case 256: return C256();
    case 257: return C257();
    case 258: return C258();
    case 259: return C259();
    case 260: return C260();
    case 261: return C261();
    case 262: return C262();
    case 263: return C263();
    case 264: return C264();
    case 265: return C265();
    case 266: return C266();
    case 267: return C267();
    case 268: return C268();
    case 269: return C269();
    case 270: return C270();
    case 271: return C271();
    case 272: return C272();
    case 273: return C273();
    case 274: return C274();
    case 275: return C275();
    case 276: return C276();
    case 277: return C277();
    case 278: return C278();
    case 279: return C279();
    case 280: return C280();
    case 281: return C281();
    case 282: return C282();
    case 283: return C283();
    case 284: return C284();
    case 285: return C285();
    case 286: return C286();
    case 287: return C287();
    case 288: return C288();
    case 289: return C289();
    case 290: return C290();
    case 291: return C291();
    case 292: return C292();
    case 293: return C293();
    case 294: return C294();
    case 295: return C295();
    case 296: return C296();
    case 297: return C297();
    case 298: return C298();
    case 299: return C299();
    case 300: return C300();
    case 301: return C301();
    case 302: return C302();
    case 303: return C303();
    case 304: return C304();
    case 305: return C305();
    case 306: return C306();
    case 307: return C307();
    case 308: return C308();
    case 309: return C309();
    case 310: return C310();
    case 311: return C311();
    case 312: return C312();
    case 313: return C313();
    case 314: return C314();
    case 315: return C315();
    case 316: return C316();
    case 317: return C317();
    case 318: return C318();
    case 319: return C319();
    case 320: return C320();
    case 321: return C321();
    case 322: return C322();
    case 323: return C323();
    case 324: return C324();
    case 325: return C325();
    case 326: return C326();
    case 327: return C327();
    case 328: return C328();
    case 329: return C329();
    case 330: return C330();
    case 331: return C331();
    case 332: return C332();
    case 333: return C333();
    case 334: return C334();
    case 335: return C335();
    case 336: return C336();
    case 337: return C337();
    case 338: return C338();
    case 339: return C339();
    case 340: return C340();
    case 341: return C341();
    case 342: return C342();
    case 343: return C343();
    case 344: return C344();
    case 345: return C345();
    case 346: return C346();
    case 347: return C347();
    case 348: return C348();
    case 349: return C349();
    case 350: return C350();
    case 351: return C351();
    case 352: return C352();
    case 353: return C353();
    case 354: return C354();
    case 355: return C355();
    case 356: return C356();
    case 357: return C357();
    case 358: return C358();
    case 359: return C359();
    case 360: return C360();
    case 361: return C361();
    case 362: return C362();
    case 363: return C363();
    case 364: return C364();
    case 365: return C365();
    case 366: return C366();
    case 367: return C367();
    case 368: return C368();
    case 369: return C369();
    case 370: return C370();
    case 371: return C371();
    case 372: return C372();
    case 373: return C373();
    case 374: return C374();
    case 375: return C375();
    case 376: return C376();
    case 377: return C377();
    case 378: return C378();
    case 379: return C379();
    case 380: return C380();
    case 381: return C381();
    case 382: return C382();
    case 383: return C383();
    case 384: return C384();
    case 385: return C385();
    case 386: return C386();
    case 387: return C387();
    case 388: return C388();
    case 389: return C389();
    case 390: return C390();
    case 391: return C391();
    case 392: return C392();
    case 393: return C393();
    case 394: return C394();
    case 395: return C395();
    case 396: return C396();
    case 397: return C397();
    case 398: return C398();
    case 399: return C399();
    case 400: return C400();
    case 401: return C401();
    case 402: return C402();
    case 403: return C403();
    case 404: return C404();
    case 405: return C405();
    case 406: return C406();
    case 407: return C407();
    case 408: return C408();
    case 409: return C409();
    case 410: return C410();
    case 411: return C411();
    case 412: return C412();
    case 413: return C413();
    case 414: return C414();
    case 415: return C415();
    case 416: return C416();
    case 417: return C417();
    case 418: return C418();
    case 419: return C419();
    case 420: return C420();
    case 421: return C421();
    case 422: return C422();
    case 423: return C423();
    case 424: return C424();
    case 425: return C425();
    case 426: return C426();
    case 427: return C427();
    case 428: return C428();
    case 429: return C429();
    case 430: return C430();
    case 431: return C431();
    case 432: return C432();
    case 433: return C433();
    case 434: return C434();
    case 435: return C435();
    case 436: return C436();
    case 437: return C437();
    case 438: return C438();
    case 439: return C439();
    case 440: return C440();
    case 441: return C441();
    case 442: return C442();
    case 443: return C443();
    case 444: return C444();
    case 445: return C445();
    case 446: return C446();
    case 447: return C447();
    case 448: return C448();
    case 449: return C449();
    case 450: return C450();
    case 451: return C451();
    case 452: return C452();
    case 453: return C453();
    case 454: return C454();
    case 455: return C455();
    case 456: return C456();
    case 457: return C457();
    case 458: return C458();
    case 459: return C459();
    case 460: return C460();
    case 461: return C461();
    case 462: return C462();
    case 463: return C463();
    case 464: return C464();
    case 465: return C465();
    case 466: return C466();
    case 467: return C467();
    case 468: return C468();
    case 469: return C469();
    case 470: return C470();
    case 471: return C471();
    case 472: return C472();
    case 473: return C473();
    case 474: return C474();
    case 475: return C475();
    case 476: return C476();
    case 477: return C477();
    case 478: return C478();
    case 479: return C479();
    case 480: return C480();
    case 481: return C481();
    case 482: return C482();
    case 483: return C483();
    case 484: return C484();
    case 485: return C485();
    case 486: return C486();
    case 487: return C487();
    case 488: return C488();
    case 489: return C489();
    case 490: return C490();
    case 491: return C491();
    case 492: return C492();
    case 493: return C493();
    case 494: return C494();
    case 495: return C495();
    case 496: return C496();
    case 497: return C497();
    case 498: return C498();
    case 499: return C499();
    case 500: return C500();
    case 501: return C501();
    case 502: return C502();
    case 503: return C503();
    case 504: return C504();
    case 505: return C505();
    case 506: return C506();
    case 507: return C507();
    case 508: return C508();
    case 509: return C509();
    case 510: return C510();
    case 511: return C511();
  }
  return C0();
}

@pragma('vm:never-inline')
String site(dynamic d, int x) => d.v(x) as String;

void main() {
  var acc = 0;
  for (var i = 0; i < 512; i++) {
    acc += site(mk(i), input).length;
  }
  print('scale.count=512');
  print('scale.acc=$acc');
}
