import bcrypt from "bcrypt";

export async function hashPassword(passwordValue: string): Promise<string> {
    return bcrypt.hash(passwordValue, 12);
}
