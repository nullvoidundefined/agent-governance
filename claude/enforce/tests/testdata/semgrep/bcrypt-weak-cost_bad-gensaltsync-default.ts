import bcrypt from "bcrypt";

export function hashPasswordSync(passwordValue: string): string {
    const salt = bcrypt.genSaltSync();
    return bcrypt.hashSync(passwordValue, salt);
}
