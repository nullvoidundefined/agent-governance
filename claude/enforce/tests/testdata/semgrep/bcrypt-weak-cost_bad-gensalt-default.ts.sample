import bcrypt from "bcrypt";

export async function hashPassword(passwordValue: string): Promise<string> {
    const salt = await bcrypt.genSalt();
    return bcrypt.hash(passwordValue, salt);
}
